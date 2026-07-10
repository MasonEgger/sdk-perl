# ABOUTME: Replay test harness (spec section 10.6): push_activation drives a
# ABOUTME: workflow Runner with hand-built activations (no server, no worker,
# ABOUTME: no IO::Async); replay_history/replay_workflow/replay_workflows push
# ABOUTME: real histories through core's replayer (spec R43 + R95).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Test::WorkflowReplay::Result ();
use Temporalio::Workflow::Runner ();
use Temporalio::Converter::Payload ();

class Temporalio::Test::WorkflowReplay {
    # The workflow Definition subclass under test (e.g. 'My::Workflow::Greeting').
    field $workflow_class :param;

    # Optional payload converter; defaults to the spec composite. Lets a test
    # inject a recording/custom converter.
    field $payload_converter :param = undef;

    # Worker-level outcome-policy options (spec section 10.3 step 6), threaded
    # to the Runner so a test can exercise the full completion decision table
    # (T-wf-13 / T-wf-15c). Defaults match a worker with no overrides.
    # The kwarg names are the Runner constructor parameter names, shared
    # verbatim with the live path (Worker/WorkflowDispatcher.pm
    # _runner_failure_options), per spec R14+R15 (findings A1/ADJ2): the live
    # worker used to drop both, so live and replay Runners diverged.
    field $workflow_failure_exception_types :param = [];
    field $nondeterminism_as_workflow_fail   :param = 0;

    # The workflow namespace (spec section 20): surfaced through
    # Temporalio::Workflow::info and used to populate the
    # NamespacedWorkflowExecution arm of external-workflow signal/cancel
    # commands. The real worker injects the client's namespace; the harness
    # defaults to a fixed value so external-handle replay tests can assert it.
    field $namespace :param = 'default';

    # The workflow execution's task queue (spec R36 / finding A5): surfaced
    # through Temporalio::Workflow::info->{task_queue} and used as the default
    # queue for scheduled activities. The real worker injects its own queue;
    # the harness default (undef) mirrors a runner built without one.
    field $task_queue :param = undef;

    # Eager activity dispatch (spec section 23.2): the worker-side flag, threaded
    # to the Runner so a replay test can assert do_not_eagerly_execute on the
    # emitted ScheduleActivity command (T-eager-6). Defaults to a worker with
    # eager activity execution enabled.
    field $disable_eager_activity_execution :param = 0;

    # The combined worker interceptor list (spec section 27.2), threaded to the
    # Runner so a replay test can assert the workflow-inbound chain is actually
    # invoked for execute_workflow / handle_signal / handle_query / handle_update
    # (#10). Defaults empty (no interceptors).
    field $interceptors :param = [];

    # A user-facing metric meter for the Runner (spec R83): a replay test can
    # inject a Temporalio::Runtime::MetricMeter::Meter over a buffer backend
    # and assert what Temporalio::Workflow::metric_meter emitted (and that
    # replay suppresses it). Defaults to undef (the Runner's noop fallback).
    field $metric_meter :param = undef;

    # The per-run Runner. Created lazily on the first push_activation so the
    # run_id from the activation seeds it (one harness drives one run, like
    # Python's WorkflowReplayer over a single run).
    #
    # Spec R43 (finding R14): this activation-pushing path exercises the Perl
    # Runner ONLY: it checks command emission, not history consistency. The
    # resolved direction is IMPLEMENT: core's history comparison is engaged
    # through the C bridge replayer (temporal_core_worker_replayer_new /
    # _replay_push, header :1073-1079) by _replay_session below, which is
    # where nondeterminism detection actually lives. replay_workflow and
    # replay_workflows (spec R95, parity audit worker finding 4 resolved as
    # from-history) are the public from-JSON / batch surface over that path.
    field $runner;

    ADJUST {
        $payload_converter //= Temporalio::Converter::Payload->default;
    }

    # push_activation($activation) -> the decoded list of WorkflowCommand
    # objects from the resulting WorkflowActivationCompletion. The activation is
    # a coresdk WorkflowActivation proto (built by the caller). Subsequent calls
    # reuse the same Runner (the same run), mirroring how the worker feeds a
    # cached runner successive activations for one run id.
    method push_activation ($activation) {
        return $self->commands_of(
            $self->push_activation_completion($activation));
    }

    # push_activation_completion($activation) -> the fully-decoded
    # WorkflowActivationCompletion proto. Unlike push_activation (which returns
    # only the commands of a SUCCESSFUL completion), this exposes the raw
    # completion so a test can inspect a TASK-failure outcome (which_status eq
    # 'failed', spec section 10.3 step 6 / T-wf-15a).
    method push_activation_completion ($activation) {
        # Normalise the activation the way the real worker receives it: fully
        # decoded off the wire, with every nested message blessed and its
        # oneof discriminator (which_variant) live. A proto built via ->new
        # from a nested hashref leaves the sub-messages as plain hashrefs, so
        # round-trip it through encode/decode to match production exactly.
        $activation = ref($activation)->decode($activation->encode);

        $runner //= Temporalio::Workflow::Runner->new(
            workflow_class                   => $workflow_class,
            run_id                           => $activation->run_id,
            payload_converter                => $payload_converter,
            workflow_failure_exception_types => $workflow_failure_exception_types,
            nondeterminism_as_workflow_fail  => $nondeterminism_as_workflow_fail,
            namespace                        => $namespace,
            task_queue                       => $task_queue,
            disable_eager_activity_execution => $disable_eager_activity_execution,
            interceptors                     => $interceptors,
            metric_meter                     => $metric_meter,
        );

        my $completion = $runner->process_activation($activation);

        # Round-trip the completion the way the worker hands it to core (encode
        # to bytes, decode back) so every nested message — Success/Failure, each
        # WorkflowCommand, its variant payloads — is fully blessed with live
        # accessors and oneof discriminators.
        return ref($completion)->decode($completion->encode);
    }

    # commands_of($completion) -> the WorkflowCommand list of a SUCCESSFUL
    # completion (empty for a `failed` completion, which carries no commands).
    method commands_of ($completion) {
        my $success = $completion->successful;
        return () unless defined $success;
        return ($success->commands // [])->@*;
    }

    # The Runner backing this harness (undef until the first push_activation).
    # Lets a test introspect runner state directly.
    method runner { return $runner }

    # replay_history(history => $history_proto_or_bytes, workflow_id => ...)
    # replays ONE recorded workflow history through core's replayer (spec R43,
    # finding R14), engaging core's command-vs-history comparison. Raises
    # Temporalio::Exception::Nondeterminism when the workflow's commands
    # diverge from the recorded events; returns 1 on a clean replay. The
    # whole run is synchronous from the caller's view (the IO::Async loop is
    # driven internally), so tests need no async plumbing. MUST-match
    # sdk-python worker/_replayer.py: same replay worker options, the same
    # on_eviction_hook reason mapping (NONDETERMINISM raises; CACHE_FULL and
    # LANG_REQUESTED are the benign end-of-replay reasons; core evicts every
    # run after replay with LangRequested, sdk-core replay/mod.rs
    # get_post_activate_hook), and the same teardown order (pusher first,
    # then worker shutdown).
    method replay_history (%args) {
        my $history     = delete $args{history};
        my $workflow_id = delete $args{workflow_id} // 'replay-workflow';
        if (my @unknown = sort keys %args) {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(message =>
                "replay_history: unknown option(s): @unknown");
        }
        if (!defined $history) {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(
                message => "replay_history: 'history' is required");
        }

        my $history_bytes =
            Scalar::Util::blessed($history) ? $history->encode : $history;
        my $failures = $self->_replay_session([
            { workflow_id => $workflow_id, history_bytes => $history_bytes },
        ]);
        die $failures->[0] if defined $failures->[0];
        return 1;
    }

    # replay_workflow($history, %opts) -> a per-history Result for ONE
    # Temporalio::Client::WorkflowHistory (fetched or from_json-loaded), the
    # spec R95 public surface (sdk-python worker/_replayer.py:110
    # replay_workflow). raise_on_replay_failure (default 1, the Python
    # default) raises the replay failure instead of returning it in the
    # Result.
    method replay_workflow ($history, %opts) {
        my $raise = delete $opts{raise_on_replay_failure} // 1;
        _assert_known_options('replay_workflow', \%opts);
        _assert_workflow_history('replay_workflow', $history);
        my $failures = $self->_replay_session([_session_item($history)]);
        die $failures->[0] if $raise && defined $failures->[0];
        return Temporalio::Test::WorkflowReplay::Result->new(
            history        => $history,
            replay_failure => $failures->[0],
        );
    }

    # replay_workflows(\@histories, %opts) -> a Results aggregate for a
    # stream of WorkflowHistory objects (spec R95; sdk-python
    # worker/_replayer.py:138 replay_workflows over :166
    # workflow_replay_iterator). ONE replay worker serves the whole batch;
    # each history is pushed in turn and its outcome recorded as a
    # per-history Result, so a nondeterministic history fails ITS result
    # while the others still replay. raise_on_replay_failure (default 1)
    # raises the first failure instead.
    method replay_workflows ($histories, %opts) {
        my $raise = delete $opts{raise_on_replay_failure} // 1;
        _assert_known_options('replay_workflows', \%opts);
        if (ref $histories ne 'ARRAY') {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(message =>
                'replay_workflows: expected an arrayref of '
                . 'Temporalio::Client::WorkflowHistory objects');
        }
        _assert_workflow_history('replay_workflows', $_) for @$histories;

        my $failures =
            $self->_replay_session([map { _session_item($_) } @$histories]);

        my (@results, %replay_failures);
        for my $i (0 .. $#$histories) {
            my $failure = $failures->[$i];
            die $failure if $raise && defined $failure;
            push @results, Temporalio::Test::WorkflowReplay::Result->new(
                history        => $histories->[$i],
                replay_failure => $failure,
            );
            $replay_failures{ $histories->[$i]->run_id } = $failure
                if defined $failure;
        }
        return Temporalio::Test::WorkflowReplay::Results->new(
            results         => \@results,
            replay_failures => \%replay_failures,
        );
    }

    # Typed strictness for the replay_workflow* option hashes (the client
    # surface rule: a typo'd option must not be silently ignored).
    sub _assert_known_options ($method_name, $opts) {
        if (my @unknown = sort keys %$opts) {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(
                message => "$method_name: unknown option(s): @unknown");
        }
        return;
    }

    sub _assert_workflow_history ($method_name, $history) {
        return
            if Scalar::Util::blessed($history)
            && $history->isa('Temporalio::Client::WorkflowHistory');
        require Temporalio::Exception::Argument;
        Temporalio::Exception::Argument->throw(message =>
            "$method_name: expected a Temporalio::Client::WorkflowHistory");
    }

    # One push item for _replay_session: the workflow_id rides alongside the
    # serialized temporal.api.history.v1.History (histories do not embed an
    # ID; sdk-python pushes history.workflow_id the same way,
    # _replayer.py:350).
    sub _session_item ($history) {
        require Temporalio::Core::Proto;
        my $proto_class = Temporalio::Core::Proto::resolve(
            'temporal.api.history.v1.History');
        return {
            workflow_id   => $history->workflow_id,
            history_bytes =>
                $proto_class->new({ events => $history->events })->encode,
        };
    }

    # Map a RemoveFromCache eviction job to a per-history failure object, or
    # undef for a clean replay (sdk-python _replayer.py on_eviction_hook).
    # EvictionReason (coresdk workflow_activation.proto): 1 CACHE_FULL and 5
    # LANG_REQUESTED end a clean replay; 3 NONDETERMINISM is the history
    # mismatch; anything else is a broken replay. This is the R43 real
    # nondeterminism check (parity audit worker finding 4, resolved as
    # IMPLEMENT the from-history replayer): R95 reuses it verbatim inside
    # the per-history batch loop, so batch and single-history replay report
    # divergence identically.
    sub _eviction_failure ($remove_job) {
        my $reason  = (defined $remove_job ? $remove_job->reason : 0) // 0;
        my $message = defined $remove_job ? ($remove_job->message // '') : '';
        if ($reason == 3) {    # NONDETERMINISM
            require Temporalio::Exception::Nondeterminism;
            return Temporalio::Exception::Nondeterminism->new(
                message => $message);
        }
        if ($reason != 1 && $reason != 5) {  # not CACHE_FULL/LANG_REQUESTED
            require Temporalio::Exception::Runtime;
            return Temporalio::Exception::Runtime->new(message =>
                "replay failed (eviction reason $reason): $message");
        }
        return undef;
    }

    # _replay_session(\@items) -> arrayref of per-item failure objects (undef
    # for a clean replay), one entry per item in push order. Each item is
    # { workflow_id, history_bytes }. One replay worker serves the whole
    # batch (sdk-python _workflow_replay_iterator: one bridge worker, N
    # pushes). Infrastructure errors (replayer build, push, poll-loop death,
    # wedged replay) THROW; history-outcome failures come back per item.
    method _replay_session ($items) {
        # Loaded lazily so activation-pushing users of this harness stay free
        # of the native bridge (the pre-R43 contract: no worker, no IO::Async).
        require Temporalio::Runtime;
        require Temporalio::Core::FFI;
        require Temporalio::Core::FFI::WorkerOptions;
        require Temporalio::Core::Callback;
        require Temporalio::Core::ByteArray;
        require Temporalio::Worker::PollLoop;
        require Temporalio::Worker::WorkflowDispatcher;
        require Temporalio::Worker::WorkflowRegistry;
        require Temporalio::Converter::Data;
        require Temporalio::Exception::Bridge;
        require Temporalio::Exception::Nondeterminism;
        require Temporalio::Exception::Runtime;
        require Future;

        my $runtime = Temporalio::Runtime->default;
        my $loop    = $runtime->loop;

        # Replay worker options (sdk-python _replayer.py parity): placeholder
        # queue/versioning; core overrides what it needs in replay mode
        # (max_cached_workflows=1, workflow-only task types, sdk-core
        # replay/mod.rs into_core_worker) but the packer requires every field.
        my @keep;
        my $options_ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
            namespace            => $namespace,
            task_queue           => $task_queue // 'perl-replay-task-queue',
            versioning_build_id  => 'perl-replayer',
            identity_override    => undef,
            max_cached_workflows => 2,
            workflow_slots       => 2,
            activity_slots       => 1,
            local_activity_slots => 1,
            nexus_task_slots     => 1,
            enable_workflows         => 1,
            enable_local_activities  => 0,
            enable_remote_activities => 0,
            enable_nexus             => 0,
            sticky_queue_schedule_to_start_timeout_millis => 1000,
            max_heartbeat_throttle_interval_millis        => 1000,
            default_heartbeat_throttle_interval_millis    => 1000,
            max_activities_per_second                     => 0,
            max_task_queue_activities_per_second          => 0,
            graceful_shutdown_period_millis               => 0,
            workflow_task_poller_simple_maximum           => 2,
            activity_task_poller_simple_maximum           => 1,
            nexus_task_poller_simple_maximum              => 1,
            nonsticky_to_sticky_poll_ratio                => 1,
            nondeterminism_as_workflow_fail =>
                ($nondeterminism_as_workflow_fail ? 1 : 0),
            nondeterminism_as_workflow_fail_for_types => [],
            plugins         => [],
            storage_drivers => [],
        );

        my $created = Temporalio::Core::FFI::worker_replayer_new(
            $runtime->core_ptr, $options_ptr);
        if (defined(my $fail_ptr = scalar $created->fail)) {
            my $byte_array =
                Temporalio::Core::ByteArray->wrap($fail_ptr, $runtime);
            my $message = $byte_array->bytes;
            $byte_array->free;
            Temporalio::Exception::Bridge->throw(
                message => "replayer creation failed: $message");
        }
        my $worker_ptr = scalar $created->worker;
        my $pusher_ptr = scalar $created->worker_replay_pusher;

        # The dispatcher is the SAME unit the live worker drives (spec 8.3),
        # completing activations against the replay worker; the on_eviction
        # hook captures the RemoveFromCache job that ends every replayed run.
        # $eviction_f is re-created per pushed history (the hook closes over
        # the variable, not a value), mirroring sdk-python's
        # last_replay_complete.clear() before each push.
        my $eviction_f;
        my $dispatcher = Temporalio::Worker::WorkflowDispatcher->new(
            registry => Temporalio::Worker::WorkflowRegistry->new(
                workflows => [$workflow_class]),
            data_converter => Temporalio::Converter::Data->new(
                payload_converter => $payload_converter),
            task_queue                       => $task_queue,
            namespace                        => $namespace,
            disable_eager_activity_execution => $disable_eager_activity_execution,
            local_activities_enabled         => 0,
            interceptors                     => $interceptors,
            workflow_failure_exception_types => $workflow_failure_exception_types,
            nondeterminism_as_workflow_fail  => $nondeterminism_as_workflow_fail,
            completer => sub ($completion_bytes) {
                my @completion_keep;
                my ($data, $size) = Temporalio::Core::FFI::keep_buffer(
                    \@completion_keep, $completion_bytes);
                my $ref = Temporalio::Core::FFI::ByteArrayRef->new(
                    data => $data, size => $size);
                my $f = Temporalio::Core::Callback->issue_async(
                    $runtime, worker => sub ($user_data, $trampoline) {
                        Temporalio::Core::FFI::worker_complete_workflow_activation(
                            $worker_ptr, $ref, $user_data, $trampoline);
                    });
                return $f->on_ready(sub { @completion_keep = (); undef $ref });
            },
            on_eviction => sub ($run_id, $remove_job) {
                $eviction_f->done($remove_job)
                    if defined $eviction_f && !$eviction_f->is_ready;
            },
        );
        my $poll_loop = Temporalio::Worker::PollLoop->new(
            dispatcher  => $dispatcher,
            poll_source => sub {
                return Temporalio::Core::Callback->issue_async(
                    $runtime, worker_poll => sub ($user_data, $trampoline) {
                        Temporalio::Core::FFI::worker_poll_workflow_activation(
                            $worker_ptr, $user_data, $trampoline);
                    });
            },
            loop => $loop,
        );
        my $poll_f = $poll_loop->run;

        # Teardown, callable from every exit path. Order matches sdk-python's
        # finally block: end the history stream (pusher) FIRST (core's mock
        # poll then cancels the worker), belt-and-braces initiate_shutdown,
        # drain the poll loop on the ShutDown sentinel, finalize, free. The
        # pusher may only be freed once no push send is in flight (the
        # c-bridge's spawned send borrows the pusher, worker.rs
        # temporal_core_worker_replay_push); every caller below reaches here
        # after the pushed history was consumed (or never sent), so it is.
        my $torn_down = 0;
        my sub teardown () {
            return if $torn_down;
            $torn_down = 1;
            Temporalio::Core::FFI::worker_replay_pusher_free($pusher_ptr);
            Temporalio::Core::FFI::worker_initiate_shutdown($worker_ptr);
            $loop->await($poll_f);
            my $finalize = Temporalio::Core::Callback->issue_async(
                $runtime, worker => sub ($user_data, $trampoline) {
                    Temporalio::Core::FFI::worker_finalize_shutdown(
                        $worker_ptr, $user_data, $trampoline);
                });
            # A finalize failure must not mask the replay outcome; the worker
            # is freed regardless (sdk-python logs-and-continues here too).
            $loop->await($finalize);
            Temporalio::Core::FFI::worker_free($worker_ptr);
            return;
        }

        # Push the histories one at a time, waiting out each run's eviction
        # before the next push (sdk-python replay_iterator: clear the
        # complete-event, push, wait). workflow_id rides alongside each
        # history (histories do not embed one); the bridge decodes the
        # History bytes synchronously, so a push fail means malformed bytes
        # and nothing was queued. The keep buffers live for the whole
        # session, comfortably outlasting the borrow inside the c-bridge's
        # spawned send.
        my @push_keep;
        my @failures;
        for my $item (@$items) {
            $eviction_f = $loop->new_future;
            my ($wid_data, $wid_size) = Temporalio::Core::FFI::keep_buffer(
                \@push_keep, $item->{workflow_id});
            my ($hist_data, $hist_size) = Temporalio::Core::FFI::keep_buffer(
                \@push_keep, $item->{history_bytes});
            my $pushed = Temporalio::Core::FFI::worker_replay_push(
                $worker_ptr, $pusher_ptr,
                Temporalio::Core::FFI::ByteArrayRef->new(
                    data => $wid_data, size => $wid_size),
                Temporalio::Core::FFI::ByteArrayRef->new(
                    data => $hist_data, size => $hist_size),
            );
            if (defined(my $fail_ptr = scalar $pushed->fail)) {
                my $byte_array =
                    Temporalio::Core::ByteArray->wrap($fail_ptr, $runtime);
                my $message = $byte_array->bytes;
                $byte_array->free;
                teardown();
                Temporalio::Exception::Bridge->throw(
                    message => "replay push failed: $message");
            }

            # Wait for the run's eviction (every replayed run ends in one) or
            # a broken completion contract (poll loop failure). The delay
            # guards CI against a wedged replay; sdk-python relies on its
            # deadlock detector here, which the Perl runner does not have.
            # The poll loop rides in as a ->without_cancel view: wait_any
            # cancels its losers, and cancelling $poll_f itself would kill
            # the in-flight eviction dispatch before its completion reaches
            # core (the "lost its returning future" wart).
            my $timeout_f = $loop->delay_future(after => 60);
            $loop->await(Future->wait_any(
                $eviction_f->without_cancel, $poll_f->without_cancel,
                $timeout_f));
            $timeout_f->cancel unless $timeout_f->is_ready;

            if ($poll_f->is_failed && !$eviction_f->is_ready) {
                teardown();
                die(($poll_f->failure)[0]);
            }
            if (!$eviction_f->is_ready) {
                teardown();
                Temporalio::Exception::Runtime->throw(message =>
                    'replay: no eviction for workflow '
                    . "'$item->{workflow_id}' within 60s (replay wedged?)");
            }

            push @failures, _eviction_failure($eviction_f->get);
        }
        teardown();

        return \@failures;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Test::WorkflowReplay - server-free replay harness for workflows

=head1 SYNOPSIS

    use Temporalio::Test::WorkflowReplay;

    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'My::Workflow::Greeting',
    );

    my @commands = $harness->push_activation(
        Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation->new({
            run_id    => 'r1',
            timestamp => { seconds => 100 },
            jobs      => [
                { initialize_workflow => {
                    workflow_type => 'Greeting',
                    arguments     => [
                        { metadata => { encoding => 'json/plain' }, data => '"Alice"' },
                    ],
                } },
            ],
        }),
    );
    # @commands is the decoded WorkflowCommand list from the completion.

=head1 DESCRIPTION

The replay test harness from spec section 10.6, with two distinct paths:

C<push_activation> constructs a L<Temporalio::Workflow::Runner> for
C<workflow_class> and feeds it hand-crafted activations, returning the
commands the runner emits. No server, no worker, no IO::Async event loop is
involved — workflow Futures are resolved imperatively by the runner from the
activation jobs, so replay is fully deterministic and synchronous. This path
checks COMMAND EMISSION only; it performs no history comparison.

C<replay_history> replays one recorded C<temporal.api.history.v1.History>
through sdk-core's replayer (spec R43): core rebuilds the activations from
the history, the same L<Temporalio::Worker::WorkflowDispatcher> the live
worker uses drives the workflow code, and core compares every emitted command
against the recorded events. A divergence raises
L<Temporalio::Exception::Nondeterminism>. Still no server (core mocks the
client internally), but the native bridge and the IO::Async loop are engaged.

C<replay_workflow> and C<replay_workflows> are the public from-history
surface over the same core replayer (spec R95, sdk-python
C<worker/_replayer.py> parity): they take
L<Temporalio::Client::WorkflowHistory> objects (fetched, or loaded from a
CLI/UI JSON download via C<from_json>) and return per-history results
instead of raising, when asked. A batch shares one replay worker; a
nondeterministic history fails its own result while the rest of the batch
still replays.

C<push_activation> returns the decoded list of C<WorkflowCommand> protos from
the resulting C<WorkflowActivationCompletion>. Successive calls reuse the same
runner (the same workflow run), mirroring how the worker feeds a cached runner
successive activations.

=head1 METHODS

=over 4

=item C<push_activation($activation)>

Apply a C<coresdk.workflow_activation.WorkflowActivation> proto and return the
emitted C<WorkflowCommand> list (empty for a failed completion until P3.7).

=item C<replay_history(history =E<gt> $history, workflow_id =E<gt> $id)>

Replay one recorded history through core's replayer (spec R43). C<history> is
required: a C<temporal.api.history.v1.History> proto object (or its serialized
bytes) whose C<WorkflowExecutionStarted> attributes MUST carry
C<original_execution_run_id>; core rejects a history without one.
C<workflow_id> is optional (histories do not embed one) and defaults to
C<replay-workflow>.

Returns 1 on a clean replay. Raises L<Temporalio::Exception::Nondeterminism>
when the workflow's commands diverge from the recorded events,
L<Temporalio::Exception::Argument> on a bad argument,
L<Temporalio::Exception::Bridge> when the replayer cannot be built or the
history bytes fail to decode, and L<Temporalio::Exception::Runtime> when the
replay ends abnormally (any eviction reason other than end-of-replay).

=item C<replay_workflow($history, %opts)>

Replay one L<Temporalio::Client::WorkflowHistory> through core's replayer
(spec R95; sdk-python C<Replayer.replay_workflow>). Returns a
C<Temporalio::Test::WorkflowReplay::Result> whose C<history> is the input
and whose C<replay_failure> is C<undef> on a clean replay or the failure
core surfaced (L<Temporalio::Exception::Nondeterminism> for a history
mismatch). With C<raise_on_replay_failure> (default 1, the Python
default), the failure is raised instead of returned. Raises
L<Temporalio::Exception::Argument> for a non-WorkflowHistory input or an
unknown option.

=item C<replay_workflows(\@histories, %opts)>

Replay a stream of L<Temporalio::Client::WorkflowHistory> objects through
ONE shared replay worker (spec R95; sdk-python C<Replayer.replay_workflows>
over C<workflow_replay_iterator>). Returns a
C<Temporalio::Test::WorkflowReplay::Results> aggregate: C<results> is the
per-history C<Result> list in push order (the synchronous stand-in for
Python's async iterator) and C<replay_failures> maps each failing
history's run id to its failure, so nondeterminism surfaces per history
while the rest of the batch still replays. With
C<raise_on_replay_failure> (default 1) the first failure is raised
instead. Argument errors as for C<replay_workflow>.

=item C<runner>

The backing L<Temporalio::Workflow::Runner> (C<undef> before the first
C<push_activation>).

=back

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Test::WorkflowReplay->new(
        workflow_class => ...,
        payload_converter => ...,
        workflow_failure_exception_types => ...,
        nondeterminism_as_workflow_fail => ...,
    );

Constructs a Temporalio::Test::WorkflowReplay. Named parameters:

=over 4

=item C<workflow_class>

(required)

=item C<payload_converter>

(optional, default C<undef>)

=item C<workflow_failure_exception_types>

(optional, default C<[]>)

=item C<nondeterminism_as_workflow_fail>

(optional, default C<0>)

=item C<task_queue>

(optional, default C<undef>): the workflow execution's task queue, surfaced
through C<Temporalio::Workflow::info-E<gt>{task_queue}>.

=item C<metric_meter>

(optional, default C<undef>): a user-facing metric meter (spec R83) for the
Runner, so a replay test can capture what
C<Temporalio::Workflow::metric_meter> emits. C<undef> falls back to the noop
meter.

=back

=head1 METHODS

=head2 commands_of

Returns the commands emitted in the completion for the activation at the given index.

=head2 push_activation_completion

Feeds one activation into the runner under test and records the resulting completion for assertion.

=cut
