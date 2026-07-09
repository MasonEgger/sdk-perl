# ABOUTME: Async activity dispatcher (spec section 8.4): decodes ActivityTask
# ABOUTME: bytes, routes start/cancel, runs the activity body under a
# ABOUTME: dynamically-scoped Activity::Context, and builds + sends the
# ABOUTME: ActivityTaskCompletion. Holds the task_token running-activities map.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Future ();
use Future::AsyncAwait;
use Scalar::Util ();
use Syntax::Keyword::Dynamically;

use Temporalio::Activity ();          # the context()/info()/heartbeat() surface
use Temporalio::Activity::Context ();
use Temporalio::Activity::Invocation ();
use Temporalio::Cancellation ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Activity::CompleteAsync ();
use Temporalio::Exception::Application ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Worker::ActivityCompletion ();
use Temporalio::Worker::Interceptor ();          # build_activity_inbound + Input::*
use Temporalio::Worker::_RootActivityInbound ();

class Temporalio::Worker::ActivityDispatcher {
    # Temporalio::Worker::ActivityRegistry: activity type name -> { code, ... }.
    field $registry :param;

    # Temporalio::Converter::Data: converts activity args/results and codec
    # decodes/encodes payloads at the worker boundary (spec section 8.4 steps
    # 4 + 7).
    field $data_converter :param;

    field $task_queue :param;
    field $client     :param = undef;
    field $loop       :param = undef;

    # The Temporalio::Activity::Pool that runs sync-declared activities in a
    # fork pool (spec section 8.4 step 6 / section 9.4). undef when the worker
    # registers no sync activities; a sync activity with no pool fails.
    field $pool :param = undef;

    # A coderef ($completion_bytes) -> Future: sends the serialized
    # ActivityTaskCompletion to core (worker_complete_activity_task over the
    # callback bridge). Injectable so unit tests capture completions without a
    # live worker.
    field $completer :param;

    # A coderef ($heartbeat_bytes) -> $error_or_undef handed to each
    # Activity::Context for synchronous heartbeat recording. undef when the
    # worker carries no heartbeat path (heartbeats then no-op Perl-side).
    field $heartbeat_recorder :param = undef;

    # The combined worker interceptor list (client-supplied then worker-supplied,
    # spec section 27.2). Each activity start folds these over a root impl that
    # runs the real body, so the activity-inbound chain is actually invoked (#10:
    # the chain was built by Worker.pm but the dispatch path never called it).
    field $interceptors :param = [];

    # task_token => { cancellation => Temporalio::Cancellation, context => ... }.
    # Added on start (step 5), used by cancel routing (step 3), removed on
    # completion (step 7).
    field %running;

    # Proto classes resolved once.
    field $ActivityTask;

    ADJUST {
        $ActivityTask = Temporalio::Core::Proto::resolve(
            'coresdk.activity_task.ActivityTask');
    }

    method registry       { $registry }
    method data_converter { $data_converter }
    method is_running ($task_token) { exists $running{$task_token} ? 1 : 0 }

    # dispatch_task($task_bytes) -> Future (spec section 8.4 step 3): decode the
    # ActivityTask and branch on its variant. A cancel resolves and returns
    # immediately; a start runs the activity body to completion (the returned
    # Future resolves once the completion is sent).
    async method dispatch_task ($task_bytes) {
        my $task = $ActivityTask->decode($task_bytes);
        my $which = $task->which_variant // '';
        if ($which eq 'cancel') {
            $self->_handle_cancel($task->task_token, $task->cancel);
            return;
        }
        if ($which eq 'start') {
            await $self->_handle_start($task->task_token, $task->start);
            return;
        }
        warn "Temporalio::Worker::ActivityDispatcher: unrecognized activity"
           . " task variant '$which' dropped\n";
        return;
    }

    # Cancel (step 3): look up the running activity by task_token and cancel its
    # token so a cooperating body sees the cancellation. No completion is sent
    # for the cancel task itself — the running activity reports via its own
    # completion. Unknown token -> warn + drop.
    method _handle_cancel ($task_token, $cancel) {
        my $entry = $running{$task_token};
        if (!defined $entry) {
            warn "Temporalio::Worker::ActivityDispatcher: cancel for unknown"
               . " activity task token '$task_token' dropped\n";
            return;
        }
        $entry->{cancellation}->cancel;
        return;
    }

    # Start (steps 4-7): decode input (codec), route to the registered activity,
    # register the running activity, run the body under a dynamically-scoped
    # Activity::Context, build + send the completion, then remove from the map.
    async method _handle_start ($task_token, $start) {
        my $cancellation = Temporalio::Cancellation->new;
        # Register before running so a concurrent cancel task can find it.
        $running{$task_token} = { cancellation => $cancellation };

        my $completion;
        try {
            my $type = $start->activity_type;
            my $def  = $registry->definition($type);
            if (!defined $def) {
                Temporalio::Exception::Application->throw(
                    message => "Activity type '$type' is not registered on this"
                        . ' worker',
                    type    => 'NotFoundError',
                );
            }

            # Step 4: codec-decode start.input at the worker boundary, then
            # convert to Perl values.
            my @args = await $data_converter->from_payloads(
                [ @{ $start->input // [] } ]);

            my $info = $self->_build_info($task_token, $start);

            # Step 6: route by the activity's sync/async declaration. A sync
            # activity runs in the fork pool (spec section 9.4); an async one
            # runs on the main loop under a dynamically-scoped Context. Either
            # way the real dispatch is the ROOT of the activity-inbound chain:
            # the combined interceptor list (client then worker, outermost
            # first) wraps it, so every inbound execute_activity is invoked in
            # order before reaching the body (#10). The root reads the body from
            # the input's private `_root` coderef (the client-outbound _RootOutbound
            # convention).
            my $inbound = Temporalio::Worker::Interceptor::build_activity_inbound(
                $interceptors,
                Temporalio::Worker::_RootActivityInbound->new);
            # Thread the activity Start task's header_fields (proto field 6) into
            # the activity-inbound input the same pass-through way the workflow
            # Runner threads InitializeWorkflow headers (#10 C-ICEPT-ACTIVITY-
            # HEADERS GAP A — the input previously carried only args/_root, so
            # $input->headers was an empty map and context propagation read
            # request_id=(none) on the activity side). The header_fields are
            # already Str => Payload off the wire, so they pass through as-is
            # (the inbound half of Temporalio::Interceptor::Headers' contract);
            # re-encoding them here would double-encode (GAP B).
            my $start_headers = $start->header_fields // {};
            # The activity info hashref rides the input too (spec R22): the
            # OTel tracing interceptor reads activity_type for the
            # RunActivity:{type} span name and the activity/workflow/run ids
            # for its span attributes, on both the sync and async paths (the
            # dynamically-scoped Activity::Context is not available to the
            # inbound chain on the sync/fork-pool path).
            my $result;
            if ($def->{sync}) {
                my $input =
                    Temporalio::Worker::Interceptor::Input::ExecuteActivity->new(
                        args    => [@args],
                        headers => { %$start_headers },
                        info    => $info,
                        _root => sub ($in) {
                            return $self->_run_in_pool($task_token, $info,
                                $cancellation, @{ $in->args });
                        },
                    );
                $result = await $inbound->execute_activity($input);
            }
            else {
                # Build the per-invocation context (spec section 9.3). info is
                # the frozen hashref the Context exposes; heartbeat flows through
                # the injected recorder.
                my $ctx = Temporalio::Activity::Context->new(
                    info               => $info,
                    cancellation       => $cancellation,
                    data_converter     => $data_converter,
                    client             => $client,
                    heartbeat_recorder => $heartbeat_recorder
                        // sub ($bytes) { return undef },
                );
                $running{$task_token}{context} = $ctx;

                my $input =
                    Temporalio::Worker::Interceptor::Input::ExecuteActivity->new(
                        args    => [@args],
                        headers => { %$start_headers },
                        info    => $info,
                        _root => sub ($in) {
                            return $self->_invoke($def->{code}, @{ $in->args });
                        },
                    );

                # Run the body with the context dynamically scoped (NEVER
                # `local` — F::AA panics across an await, spec section 16.1). The
                # `dynamically` MUST wrap the `await` itself, not just the
                # synchronous call: Syntax::Keyword::Dynamically restores the
                # value correctly across each suspend/resume, so a body that
                # parks on `await $ctx->cancellation->cancelled` still sees
                # $CURRENT when it resumes. Scoping the whole chain await keeps
                # the Context live through every inbound interceptor too.
                $result = do {
                    dynamically $Temporalio::Activity::Context::CURRENT = $ctx;
                    await $inbound->execute_activity($input);
                };
            }

            # Success (step 7): convert + codec-encode the result payload.
            my ($payload) = await $data_converter->to_payloads([$result]);
            $completion = Temporalio::Worker::ActivityCompletion::success(
                $task_token, $payload);
        }
        catch ($error) {
            # Out-of-band completion (spec section 22): an activity body that
            # threw CompleteAsync (via Temporalio::Activity::complete_async)
            # reports will_complete_async to core instead of Completed/Failed.
            # Only honored when it propagates out of the body — user code that
            # catches it defeats async completion.
            if (Scalar::Util::blessed($error)
                && $error->isa('Temporalio::Exception::Activity::CompleteAsync'))
            {
                $completion =
                    Temporalio::Worker::ActivityCompletion::will_complete_async(
                        $task_token);
            }
            else {
                $completion = await $self->_failure_completion(
                    $task_token, $cancellation, $error);
            }
        }

        # Step 7: send the completion, then drop the running entry.
        try {
            await $completer->($completion);
        }
        catch ($send_error) {
            warn "Temporalio::Worker::ActivityDispatcher: sending completion"
               . " for '$task_token' failed: $send_error\n";
        }
        delete $running{$task_token};
        return;
    }

    # Invoke the activity callable. A `code` ref may be async (returns a Future)
    # or sync (returns a plain value). Future->call routes a synchronous die into
    # the Future, but it REQUIRES its block to return a Future — a plain return
    # value makes it die ("Expected ... to return a Future"). Wrapping the call
    # in Future->wrap normalises both shapes: a returned Future passes through
    # unchanged, a plain value (or list) becomes an immediately-done Future. So
    # async-returning bodies and plain-value bodies both resolve uniformly, and a
    # synchronous die still becomes a failed Future the caller can convert.
    method _invoke ($code, @args) {
        return Future->call(sub { Future->wrap($code->(@args)) });
    }

    # Run a sync activity in the fork pool (spec section 9.4). Builds the
    # serializable cross-fork invocation struct — activity type, already-decoded
    # args (plain scalars), the info hashref, task token, and the cooperative
    # cancellation flag — and awaits the pool. No live core pointers or
    # Cancellation objects cross the fork. Cancellation crosses it twice
    # (spec R19, finding L15): a cancel that already happened rides the
    # frozen `cancelled` flag, and the `cancellation` option lets the pool
    # forward a cancel that fires WHILE the child runs down its live control
    # channel — pre-R19 the flag below was the ONLY hand-off, so a cancel
    # task arriving mid-body (_handle_cancel cancelling this token) was
    # invisible in-child and the body ran to completion.
    async method _run_in_pool ($task_token, $info, $cancellation, @args) {
        Temporalio::Exception::Application->throw(
            message => 'Sync activity dispatched but the worker has no activity'
                . ' pool configured',
            type    => 'NotFoundError',
        ) if !defined $pool;

        my $inv = Temporalio::Activity::Invocation->new(
            activity_type => $info->{activity_type},
            args          => [@args],
            info          => $info,
            task_token    => $task_token,
            cancelled     => $cancellation->is_cancelled,
        );
        return await $pool->invoke($inv, cancellation => $cancellation);
    }

    # Build the failed/cancelled completion for a thrown $error. A Cancelled
    # error whose token was actually cancelled (server cancel) reports the
    # cancelled outcome (mirrors sdk-ruby run_activity); everything else is a
    # failure. The failure proto is codec-encoded by data_converter->to_failure.
    async method _failure_completion ($task_token, $cancellation, $error) {
        my $exception = _as_exception($error);
        my $failure   = await $data_converter->to_failure($exception);

        if (Scalar::Util::blessed($exception)
            && $exception->isa('Temporalio::Exception::Cancelled')
            && $cancellation->is_cancelled)
        {
            return Temporalio::Worker::ActivityCompletion::cancelled(
                $task_token, $failure);
        }
        return Temporalio::Worker::ActivityCompletion::failure(
            $task_token, $failure);
    }

    # Normalize a thrown value into a Temporalio::Exception so the failure
    # converter has something to map. A plain string death becomes an
    # ApplicationError (mirrors the reference SDKs wrapping arbitrary errors).
    # Pooled sync-activity failures arrive here as blessed exceptions the
    # pool's structured-error channel rebuilt (Activity/Pool.pm _thaw_error,
    # spec R5 / finding L14), so the pass-through branch preserves their
    # original class, type, non_retryable, details, and cause chain. The
    # pre-R5 channel delivered a stringified $@ that fell into the wrapper
    # branch below and came back generic and RETRYABLE: a permanently
    # failing pooled activity retried forever. The string branch remains for
    # in-process plain deaths and the pool channel's degraded string
    # fallback.
    sub _as_exception ($error) {
        return $error
            if Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception');
        my $message = "$error";
        chomp $message;
        return Temporalio::Exception::Application->new(message => $message);
    }

    # Build the frozen ActivityInfo hashref the Context exposes (spec section
    # 9.3). The schedule/start timestamps and durations stay as their proto
    # sub-messages in v0.1 (the Context exposes the hashref as-is; a typed Info
    # value class can come later — P2.3 lessons).
    method _build_info ($task_token, $start) {
        my $exec = $start->workflow_execution;
        return {
            activity_id     => $start->activity_id,
            activity_type   => $start->activity_type,
            attempt         => $start->attempt,
            task_queue      => $task_queue,
            task_token      => $task_token,
            namespace       => $start->workflow_namespace,
            workflow_id     => defined $exec ? $exec->workflow_id : undef,
            workflow_run_id => defined $exec ? $exec->run_id : undef,
            workflow_type   => $start->workflow_type,
            is_local        => $start->is_local ? 1 : 0,
            heartbeat_details              => $start->heartbeat_details,
            scheduled_time                 => $start->scheduled_time,
            current_attempt_scheduled_time => $start->current_attempt_scheduled_time,
            started_time                   => $start->started_time,
            schedule_to_close_timeout      => $start->schedule_to_close_timeout,
            start_to_close_timeout         => $start->start_to_close_timeout,
            heartbeat_timeout              => $start->heartbeat_timeout,
        };
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::ActivityDispatcher - run activity tasks and report results

=head1 SYNOPSIS

    use Temporalio::Worker::ActivityDispatcher ();

    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $activity_registry,
        data_converter => $data_converter,
        task_queue     => 'demo',
        client         => $client,
        loop           => $io_async_loop,
        completer      => sub ($bytes) { ... return Future },
        heartbeat_recorder => sub ($bytes) { ... return $err_or_undef },
    );

    await $dispatcher->dispatch_task($activity_task_bytes);

=head1 DESCRIPTION

The async activity dispatcher of spec section 8.4. C<dispatch_task> decodes a
serialized C<coresdk.activity_task.ActivityTask> and branches on its variant:

=over

=item C<cancel>

Looks up the running activity by C<task_token> in the dispatcher's
running-activities map and cancels its L<Temporalio::Cancellation> so a
cooperating body observing C<< $ctx->cancellation >> sees the cancellation. No
completion is sent for the cancel task itself; the running activity reports via
its own completion. An unknown token is warned about and dropped.

=item C<start>

Codec-decodes C<start.input> (the worker boundary), routes by C<activity_type>
to the registered activity (an unregistered type completes failed with a
C<NotFoundError> ApplicationError), records the activity in the
C<task_token>-keyed map, and runs the body under a dynamically-scoped
L<Temporalio::Activity::Context> (B<C<dynamically>, never C<local>> — F::AA
panics across an await). On normal return it builds a success
C<ActivityTaskCompletion> with the converted + codec-encoded result; on a
thrown error it builds a failed completion (or a cancelled completion when a
L<Temporalio::Exception::Cancelled> coincides with an actually-cancelled
token, mirroring sdk-ruby). A body that throws
L<Temporalio::Exception::Activity::CompleteAsync> (via
L<Temporalio::Activity/complete_async>) instead reports
C<will_complete_async> to core: the activity will complete out of band through
a L<Temporalio::Client::AsyncActivityHandle> (spec section 22). The completion
bytes are handed to the injected C<completer> and the running entry is removed.

=back

Both the completer and the heartbeat recorder are injected so the dispatcher
is unit-testable without a live worker; L<Temporalio::Worker> supplies real
ones over the callback bridge. Completion building is delegated to
L<Temporalio::Worker::ActivityCompletion>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Worker::ActivityDispatcher->new(
        registry => ...,
        data_converter => ...,
        task_queue => ...,
        client => ...,
        loop => ...,
        pool => ...,
        completer => ...,
        heartbeat_recorder => ...,
    );

Constructs a Temporalio::Worker::ActivityDispatcher. Named parameters:

=over 4

=item C<registry>

(required)

=item C<data_converter>

(required)

=item C<task_queue>

(required)

=item C<client>

(optional, default C<undef>)

=item C<loop>

(optional, default C<undef>)

=item C<pool>

(optional, default C<undef>)

=item C<completer>

(required)

=item C<heartbeat_recorder>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 data_converter

Accessor returning the C<data_converter> value.

=head2 dispatch_task

Async. Dispatches one polled activity task to its registered definition and returns a L<Future> resolving to the activity completion.

=head2 is_running

Returns true while there are in-flight activity tasks.

=head2 registry

Accessor returning the C<registry> value.

=cut
