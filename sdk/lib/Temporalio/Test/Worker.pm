# ABOUTME: Integration-test glue (P3.9) for driving a live worker: run the
# ABOUTME: worker's poll loops concurrently with a test body, then shut down and
# ABOUTME: drain cleanly. Keeps DevServer-backed tests free of boilerplate.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Scalar::Util ();
use Temporalio::Exception::RpcTimeout ();
use Temporalio::Exception::WorkflowAlreadyStarted ();

class Temporalio::Test::Worker {
    # The worker under test and the IO::Async loop its runtime drives.
    field $worker :param;
    field $loop   :param;

    # The worker's run future, started in ADJUST so the poll loops are live
    # before the test body awaits any workflow result.
    field $run_future;

    ADJUST {
        $run_future = $worker->run;
    }

    method worker { $worker }

    # await_result($future, $timeout=60) -> the resolved value. Awaits $future
    # while the worker's poll loops run concurrently. If the worker's run loop
    # crashes before $future resolves, that failure is surfaced (rather than the
    # test hanging until the timeout). A genuine timeout dies with a clear
    # message. The worker run future is protected from cancellation so awaiting a
    # result never tears the running worker down.
    method await_result ($future, $timeout = 120) {
        $loop->await(Future->wait_any(
            $future,
            $run_future->without_cancel,
            $loop->timeout_future(after => $timeout),
        ));
        if ($run_future->is_ready && $run_future->is_failed && !$future->is_ready)
        {
            die 'worker run loop failed: ' . (($run_future->failure)[0] // '');
        }
        die "future did not resolve within ${timeout}s\n"
            unless $future->is_ready;
        return $future->get;
    }

    # _is_transient_load_error($err) -> bool. True for the transient gRPC-layer
    # failures a loaded box raises around a server call when it starves the
    # worker — the ONE shared classifier for connect + idempotent read + teardown
    # retries (P10.0.5, P10.0.6). It matches:
    #   * a clean DEADLINE_EXCEEDED (Temporalio::Exception::RpcTimeout);
    #   * an UNAVAILABLE (gRPC 14);
    #   * an RpcError whose message is a mid-call transport hiccup (h2/http2
    #     protocol error, connection reset, broken pipe, bare transport error);
    #   * the dev-server CONNECT race (P10.0.6): an ephemeral server that has
    #     started but not yet bound/accepted makes the bridge surface
    #     "Connection failed: ...ConnectionRefused..." / "tcp connect error" /
    #     "connection refused" / "Failed connecting to test server" /
    #     "TonicTransportError". The just-started server only needs a moment to
    #     listen, so a resilient connect retries these.
    # All of these are the SAME load/race artifact and safe to re-issue on an
    # idempotent read or a connect. Deliberately NARROW: NOT_FOUND /
    # ALREADY_EXISTS / FAILED_PRECONDITION (QueryRejected) / PERMISSION_DENIED /
    # UNAUTHENTICATED / INVALID_ARGUMENT are real, non-transient outcomes and
    # must surface at once. A TLS-mismatch connect failure ("Connection failed:
    # ...handshake...") is a real misconfiguration, NOT a race — it carries none
    # of the connect-refused tokens below, so it correctly does not match.
    sub _is_transient_load_error ($err) {
        return 0 unless Scalar::Util::blessed($err);
        return 1 if $err->isa('Temporalio::Exception::RpcTimeout');
        return 0 unless $err->isa('Temporalio::Exception::RpcError');
        my $name = $err->status_name // '';
        return 1 if $name eq 'unavailable' || $name eq 'UNAVAILABLE';
        my $msg = $err->message // '';
        return 1 if $msg =~ /
            \b h2 \b | http2 | transport \s+ error
            | connection \s+ reset | broken \s+ pipe | connection \s+ closed
            | connection \s* refused | connectionrefused
            | tcp \s+ connect \s+ error | failed \s+ connecting \s+ to
            | tonictransport
        /xi;
        return 0;
    }

    # await_idempotent($producer, %opts) -> the resolved value. $producer is a
    # coderef returning a FRESH Future per call (so a retry re-issues the RPC).
    # Wraps await_result, but absorbs a transient load-stall transport failure
    # (see _is_transient_load_error) by retrying up to %opts{attempts} times with
    # a short %opts{backoff} pause between tries. RETRY IS SAFE ONLY FOR IDEMPOTENT
    # operations — query, fetch result/describe, poll loops — where a re-issued
    # call has no side effect. Do NOT use it for start_workflow (would surface
    # WorkflowAlreadyStarted) or signal (would double-deliver). Any non-transient
    # failure is raised immediately, never retried, so this never masks a real
    # error; a persistent transient failure surfaces after the last attempt.
    method await_idempotent ($producer, %opts) {
        # Generous test-harness ceilings (P10.0.5/P10.0.6): on a 4-core,
        # 7.8 GiB/no-swap box under full CPU saturation a single read can eat
        # several consecutive DEADLINE_EXCEEDED before the worker is scheduled
        # again. A memory-reclaim stall (worst on a small/low-swap box) can
        # freeze the worker for tens of seconds, during which the workflow makes
        # no progress and every read deadlines; the budget rides that out
        # (30 attempts over ~75s) rather than the bare-minimum 3. A genuine hang
        # fails every run, not just the slowest, so this masks no real bug. The
        # retries cost nothing on a healthy run (the first attempt succeeds);
        # the wide budget only spends time during an actual stall. Callers
        # needing a tighter bound pass attempts/backoff.
        my $attempts = $opts{attempts} // 30;
        my $backoff  = $opts{backoff}  // 2.5;
        my $timeout  = $opts{timeout}  // 120;
        for my $attempt (1 .. $attempts) {
            my ($value, $ok, $err);
            {
                local $@;
                $ok = eval { $value = $self->await_result($producer->(), $timeout); 1 };
                $err = $@;
            }
            return $value if $ok;
            die $err
                if !_is_transient_load_error($err) || $attempt == $attempts;
            $loop->await($loop->delay_future(after => $backoff)) if $backoff > 0;
        }
        # Unreachable: the loop either returns or dies on the last attempt.
        return;
    }

    # await_with_retry($producer, %opts) -> the resolved value. The sibling of
    # await_idempotent for the NON-idempotent harness calls — start_workflow,
    # signal, terminate — which on a starved box can eat a clean DEADLINE_EXCEEDED
    # ("Timeout expired") whose RPC may or may not have reached the server
    # (P10.0.6 run7/run9). $producer returns a FRESH Future per call. A transient
    # load failure (the SAME _is_transient_load_error classifier as connect/read)
    # is retried up to %opts{attempts} times with a %opts{backoff} pause. The one
    # hazard of retrying a non-idempotent call — the prior attempt actually
    # landed — is handled by %opts{on_already_started}: if a retry raises
    # WorkflowAlreadyStarted (the first attempt DID reach the server), that
    # callback is invoked and its return value is the result (e.g. re-fetch the
    # existing handle), so a partially-applied start still resolves cleanly. With
    # no such callback the WorkflowAlreadyStarted surfaces. Any other
    # non-transient failure is raised at once, never retried.
    method await_with_retry ($producer, %opts) {
        my $attempts = $opts{attempts} // 30;
        my $backoff  = $opts{backoff}  // 2.5;
        my $timeout  = $opts{timeout}  // 120;
        my $on_already_started = $opts{on_already_started};
        for my $attempt (1 .. $attempts) {
            my ($value, $ok, $err);
            {
                local $@;
                $ok = eval { $value = $self->await_result($producer->(), $timeout); 1 };
                $err = $@;
            }
            return $value if $ok;

            # A retry of a non-idempotent start whose prior attempt actually
            # reached the server: treat WorkflowAlreadyStarted as success.
            if ($attempt > 1
                && Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::WorkflowAlreadyStarted')
                && $on_already_started)
            {
                return $on_already_started->();
            }

            die $err
                if !_is_transient_load_error($err) || $attempt == $attempts;
            $loop->await($loop->delay_future(after => $backoff)) if $backoff > 0;
        }
        # Unreachable: the loop either returns or dies on the last attempt.
        return;
    }

    # start_workflow_with_retry($client, $type, $args, %start_opts) -> handle.
    # The common case of await_with_retry: start a workflow whose id is unique
    # per call, so a retry that hits WorkflowAlreadyStarted just re-fetches the
    # existing handle. Centralizes the on_already_started fallback so the dozens
    # of integration start sites need no bespoke callback. %start_opts carries the
    # workflow `id` and the usual start options (task_queue, etc.). The retry-
    # control keys (attempts, backoff, timeout) are peeled off here and routed to
    # await_with_retry rather than forwarded to start_workflow (which rejects
    # unknown options).
    method start_workflow_with_retry ($client, $type, $args, %start_opts) {
        my %retry_opts;
        for my $k (qw(attempts backoff timeout)) {
            $retry_opts{$k} = delete $start_opts{$k} if exists $start_opts{$k};
        }
        my $id = $start_opts{id};
        return $self->await_with_retry(
            sub { $client->start_workflow($type, $args, %start_opts) },
            on_already_started => sub { $client->get_workflow_handle($id) },
            %retry_opts,
        );
    }

    # shutdown($timeout=60): initiate worker shutdown so the poll loops drain on
    # the ShutDown sentinel, then await the run future so finalize + free + fork
    # pool teardown all complete (no orphaned processes). Idempotent.
    method shutdown ($timeout = 120) {
        $worker->shutdown;
        $loop->await(Future->wait_any(
            $run_future, $loop->timeout_future(after => $timeout)));
        die "worker run did not drain within ${timeout}s\n"
            unless $run_future->is_ready;
        # Retrieve the run future's outcome so it is never abandoned: an
        # un-retrieved failed Future warns (and dirties the process exit) at
        # global destruction. A genuine shutdown failure is re-raised so the
        # test sees it; expected shutdown-time transport teardown is already
        # swallowed inside the worker's finalize (Worker.pm P10.0), so reaching
        # here with a failure means a real error.
        if ($run_future->is_failed) {
            die 'worker run loop failed during shutdown: '
                . (($run_future->failure)[0] // '');
        }
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Test::Worker - drive a live worker from an integration test

=head1 SYNOPSIS

    use Temporalio::Test::Worker ();

    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->await_result($client->start_workflow(...));
    my $result = $tw->await_result($handle->result);

    $tw->shutdown;   # initiate -> drain -> finalize -> free; reaps fork pool

=head1 DESCRIPTION

Test-only glue (spec section 11, P3.9) for DevServer-backed integration tests
that need a running worker. Constructing one starts the worker's
C<run> poll loops; C<await_result> awaits a future (a workflow start, a
workflow result, ...) while the loops run concurrently, surfacing a worker-loop
crash promptly instead of hanging; C<shutdown> tears the worker down cleanly.

This lives under C<Temporalio::Test::> alongside
L<Temporalio::Test::DevServer> and L<Temporalio::Test::WorkflowReplay> — author
glue, not part of the public SDK surface.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Test::Worker->new(
        worker => ...,
        loop => ...,
    );

Constructs a Temporalio::Test::Worker. Named parameters:

=over 4

=item C<worker>

(required)

=item C<loop>

(required)

=back

=head1 METHODS

=head2 await_result

Async. Returns a L<Future> resolving once the worker's run loop has finished.

=head2 await_idempotent

    my $value = $tw->await_idempotent(sub { $handle->query('name') });
    my $value = $tw->await_idempotent($producer, attempts => 3, backoff => 0.5);

Awaits an idempotent read (query, fetch result/describe) with a bounded retry
around a transient load-stall transport failure, which a loaded test box can
raise when it starves the worker mid-call: C<Temporalio::Exception::RpcTimeout>
(gRPC C<DEADLINE_EXCEEDED>), C<UNAVAILABLE>, or the C<RpcError> catch-all whose
message is an h2/http2 protocol error, connection reset, broken pipe, or bare
transport error. C<$producer> is a coderef returning a B<fresh> L<Future> per
attempt so a retry re-issues the RPC. Only these transient failures are retried;
any real, non-transient error (C<NOT_FOUND>, C<QueryRejected>, etc.) surfaces
immediately, and a persistent transient failure surfaces after the last attempt.
B<Use for idempotent operations only>: never C<start_workflow>
(C<WorkflowAlreadyStarted>) or C<signal> (double-delivery).

=head2 await_with_retry

    my $handle = $tw->await_with_retry(
        sub { $client->start_workflow('Wf', [], id => $id, task_queue => $tq) },
        on_already_started => sub { $client->workflow_handle($id) },
    );
    $tw->await_with_retry(sub { $handle->signal('setName', ['Ada']) });

The non-idempotent sibling of C<await_idempotent>, for C<start_workflow>,
C<signal>, and C<terminate>, which on a CPU-saturated test box can eat a clean
C<DEADLINE_EXCEEDED> (C<Temporalio::Exception::RpcTimeout>) whose RPC may or may
not have reached the server. The same transient classifier is retried up to
C<attempts> times (default 6) with a C<backoff> pause (default 1.0s). The hazard
of retrying a non-idempotent call — the prior attempt actually landed — is
covered by the optional C<on_already_started> callback: if a retry raises
C<Temporalio::Exception::WorkflowAlreadyStarted>, that callback runs and its
return value becomes the result (e.g. re-fetch the existing handle). Without the
callback, C<WorkflowAlreadyStarted> surfaces. Any other non-transient failure is
raised immediately.

=head2 start_workflow_with_retry

    my $handle = $tw->start_workflow_with_retry(
        $client, 'MyWorkflow', [@args], id => $id, task_queue => $tq);

The common application of C<await_with_retry>: start a workflow whose C<id>
(passed in the start options) is unique per call, retrying a transient timeout
and re-fetching the handle if a retry hits C<WorkflowAlreadyStarted>. Returns
the workflow handle. Centralizes the C<on_already_started> fallback so
integration start sites need no bespoke callback.

=head2 shutdown

Initiates worker shutdown and returns a L<Future> that completes once the poll loops drain.

=head2 worker

Accessor returning the C<worker> value.

=cut
