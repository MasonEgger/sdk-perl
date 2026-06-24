# ABOUTME: The deterministic workflow Runner (spec section 10.3) — one instance
# ABOUTME: per workflow run. Applies activation jobs, drives the workflow body
# ABOUTME: via manually-resolved Futures (NEVER IO::Async), buffers commands.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Scalar::Util ();
use Syntax::Keyword::Dynamically;
use Math::Random::ISAAC::XS ();

use Temporalio::Workflow::Commands ();
use Temporalio::Workflow::Future ();
use Temporalio::Workflow::Logger ();
use Temporalio::Workflow::ContinueAsNew ();
use Temporalio::Converter::Payload ();
use Temporalio::Converter::Failure ();
use Temporalio::Core::Proto ();
use Temporalio::Exception ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Exception::ChildWorkflow ();
use Temporalio::Exception::WorkflowAlreadyStarted ();
use Temporalio::Exception::Timeout ();
use Temporalio::Exception::Nondeterminism ();
use Temporalio::Exception::Workflow::NoRunner ();
use Temporalio::Exception::Argument ();
use Temporalio::Common::SearchAttributeUpdate ();

# The dynamically-scoped pointer to the currently-active runner. Every
# Temporalio::Workflow:: context function looks it up here (spec section 10.2).
# The runner sets it via `dynamically` around the workflow body so it is
# correctly torn down across an `await` (Future::AsyncAwait panics on `local`
# — spec section 16.1). It MUST live in the Temporalio::Workflow::Runner
# package (the functional surface reads $Temporalio::Workflow::Runner::CURRENT);
# this file has no leading `package` statement, so name the package explicitly
# for the declaration rather than relying on the ambient package being `main`.
package Temporalio::Workflow::Runner { our $CURRENT; }

# One instance per workflow run (cached by the dispatcher on run_id; the
# dispatcher cache itself lands in P3.6). Owns the workflow Definition
# instance, the deterministic RNG, the activation context (timestamp,
# is_replaying, run_id, workflow_type), the outbound command buffer, the
# pending-Futures map (populated by P3.4 activities / P3.5 timers), and the
# main run Future.
class Temporalio::Workflow::Runner {
    # The workflow type name and its backing Definition subclass (resolved by
    # the harness/dispatcher from the InitializeWorkflow job's workflow_type).
    field $workflow_class :param;
    field $run_id         :param = undef;

    # The workflow namespace (spec section 20): surfaced through `info` and used
    # to populate the NamespacedWorkflowExecution arm of external-workflow
    # signal/cancel commands. The worker injects the client's namespace; the
    # replay harness defaults it. Never a user argument to signal/cancel.
    field $namespace :param = 'default';

    # Payload converter for arguments (in) and the result (out). The replay
    # harness uses the default composite; a worker injects its data converter.
    field $payload_converter :param = undef;

    # Failure converter for ResolveActivity{failed/cancelled} job failures
    # (maps the Failure proto to a Temporalio::Exception::* at the await site).
    field $failure_converter :param = undef;

    # The workflow's own task queue — the default task queue for scheduled
    # activities when execute_activity/start_activity does not override it
    # (MUST-match sdk-python: ScheduleActivity.task_queue defaults to the
    # workflow execution's task queue). The replay harness leaves it undef.
    field $task_queue :param = undef;

    # Eager activity dispatch (spec section 23.2): the worker-level workflow-side
    # flag. When true, every ScheduleActivity command sets do_not_eagerly_execute
    # so core does not try to run the activity eagerly on the local worker
    # (MUST-match sdk-python _workflow_instance.py do_not_eagerly_execute). The
    # worker injects it; the replay harness exposes it as a constructor kwarg.
    field $disable_eager_activity_execution :param = 0;

    # Worker-level workflow_failure_exception_types (spec section 10.3 step 6 /
    # T-wf-15c): an arrayref of class names. A NON-Temporal exception escaping
    # :Run fails the WORKFLOW (FailWorkflowExecution) only when its class is one
    # of these (or a subclass); otherwise it fails the TASK. MUST-match
    # sdk-python workflow_is_failure_exception (the worker-level
    # failure_exception_types).
    field $workflow_failure_exception_types :param = [];

    # Worker option nondeterminism_as_workflow_fail (spec section 10.3 step 6 /
    # T-wf-13): when false (default), a non-determinism error fails the workflow
    # TASK (the server retries); when true, it fails the WORKFLOW.
    field $nondeterminism_as_workflow_fail :param = 0;

    field $instance;                 # the workflow Definition instance
    field $workflow_type;            # resolved run type name
    field @commands;                 # outbound WorkflowCommand buffer
    field $main_run_future;          # the Future returned by :Run

    # Per-command-type sequence counters (spec section 10.3): each is
    # workflow-scoped, monotonic, starting at 1. Activities and timers allocate
    # from SEPARATE seq spaces (MUST-match sdk-python _next_seq("activity") vs
    # _next_seq("timer"); sdk-ruby @activity_counter vs @timer_counter), so a
    # workflow's first activity and first timer are both seq 1. Each is
    # matched on the corresponding ResolveActivity / FireTimer job.
    field $activity_seq_counter = 0;
    field $timer_seq_counter    = 0;

    # Child workflows use a SEPARATE seq space from activities and timers (spec
    # section 18.2; MUST-match sdk-python _next_seq("child_workflow")): a
    # workflow's first child, first activity, and first timer are each seq 1 in
    # their own space. Each is matched on the corresponding
    # ResolveChildWorkflowExecutionStart / ResolveChildWorkflowExecution job.
    field $child_workflow_seq_counter = 0;

    # Pending child workflow handles keyed by their StartChildWorkflowExecution
    # seq: { seq => $handle }. Each Temporalio::Workflow::ChildWorkflowHandle
    # owns a start Future and a result Future, resolved imperatively in two
    # stages (spec section 18.2): the seq stays mapped after the start succeeds
    # (the result job still comes) and is removed only on start-failure/cancel
    # or on the terminal ResolveChildWorkflowExecution. Child workflows also
    # allocate signal/cancel commands; the pending signal Futures from a child
    # handle's ->signal live in %pending_external_signals below.
    field %pending_child_workflows;

    # Pending external-signal Futures keyed by their
    # SignalExternalWorkflowExecution seq. Both a child-targeted signal
    # ($handle->signal on the child_workflow_id arm, spec section 18) and an
    # external-handle signal (the workflow_execution arm, spec section 20) draw
    # from this one seq space and pending map — they are the same coresdk
    # command (MUST-match sdk-python _next_seq("external_signal")). Resolved on
    # ResolveSignalExternalWorkflow.
    field %pending_external_signals;
    field $external_signal_seq_counter = 0;   # external-signal seq space.

    # Pending external-cancel Futures keyed by their
    # RequestCancelExternalWorkflowExecution seq (spec section 20). This is a
    # SEPARATE seq space from external signals (MUST-match sdk-python
    # _next_seq("external_cancel") / sdk-ruby's two counters): a workflow's
    # first external signal and first external cancel are both seq 1. Resolved
    # on ResolveRequestCancelExternalWorkflow.
    field %pending_external_cancels;
    field $external_cancel_seq_counter = 0;   # external-cancel seq space.

    # Pending activity Futures keyed by their command seq: { seq => $future }.
    # The Workflow::Future for each in-flight activity, resolved imperatively
    # when its ResolveActivity job arrives (P3.4). Child workflows (Phase 6+)
    # join analogous maps.
    field %pending_activities;

    # Activity seqs whose Future was cancelled before/while a ResolveActivity
    # arrived (spec section 10.3 cancel chain / T-act-9). When a CancelWorkflow
    # propagates down the tree, each in-flight activity Future is cancelled: it
    # emits RequestCancelActivity (unless ABANDON) and fails its Future with
    # Cancelled immediately so the awaiting body completes cancelled in the same
    # activation (mirroring sdk-python's asyncio.shield: the await raises
    # CancelledError while the underlying op resolves later). Core still sends a
    # later ResolveActivity{cancelled} for the same seq; this set lets
    # _apply_resolve_activity treat that as a tolerated STALE resolution rather
    # than an unknown-seq non-determinism error (the same way _apply_fire_timer
    # tolerates a stale FireTimer for a cancelled timer). Run-scoped.
    field %cancelled_activity_seqs;

    # Local-activity bookkeeping (spec section 21). LAs share the activity seq
    # space and %pending_activities with regular activities (a single map by
    # seq), but the backoff -> server-timer -> re-schedule loop is runner-owned
    # and needs per-LA state the runner re-uses when re-scheduling:
    #   %local_activity_state{$seq} = {
    #       future  => the SINGLE stable outer Workflow::Future the body awaits,
    #       fields  => the ScheduleLocalActivity field hashref (sans seq), so a
    #                  backoff re-schedule re-emits the same type/args/timeouts,
    #       summary => the optional summary Payload (re-applied on re-schedule),
    #   }
    # On a `backoff` resolution the runner starts a real timer; when that timer
    # fires it re-schedules under a NEW seq, moving the state entry to the new
    # seq (the outer future is preserved, so the body sees one result).
    field %local_activity_state;

    # Backoff timers in flight: { timer_seq => $la_seq } so a fired timer knows
    # which LA to re-schedule, and a whole-workflow cancel of a backing-off LA
    # (T-local-13) can find and cancel the pending backoff timer.
    field %local_activity_backoff_timers;

    # Pending timer Futures keyed by their StartTimer seq: { seq => $future }.
    # Resolved imperatively when the matching FireTimer job arrives (P3.5), or
    # removed and failed-as-cancelled when the timer Future is cancelled.
    field %pending_timers;

    # Activation context (set per activation; never the OS clock).
    field $activation_seconds = 0;
    field $activation_nanos   = 0;
    field $is_replaying       = 0;

    # Deterministic RNG (a Math::Random::ISAAC::XS instance seeded from the
    # InitializeWorkflow job's randomness_seed — spec section 10.4; re-created
    # on an UpdateRandomSeed job). See _make_rng below.
    field $rng;

    # Patches notified by the server for this run (spec section 10.3
    # NotifyHasPatch / 10.4 versioning). A set of patch ids present in history;
    # during replay, patched($id) returns true iff $id is here (MUST-match
    # sdk-python self._patches_notified). Workflow-scoped (persists across
    # activations) and surfaced in workflow info.
    field %patches_notified;

    # Memoized patched() answers keyed by patch id (MUST-match sdk-python
    # self._patches_memoized): once patched($id) has computed an answer for this
    # run it returns the same answer (and emits no further SetPatchMarker) so the
    # decision is deterministic and the marker is emitted at most once.
    field %patches_memoized;

    # The replay-aware workflow logger (spec section 10.4 / T-wf-9), lazily
    # built on first access so a run that never logs pays nothing.
    field $logger;

    # Cancellation flag (spec section 10.3 CancelWorkflow / step 6). Set when a
    # CancelWorkflow job arrives; the outcome decision table promotes a
    # Cancelled escaping :Run to CancelWorkflowExecution only when this is set
    # (MUST-match sdk-python self._cancel_requested gating cancel_workflow_execution).
    field $cancel_requested = 0;

    # A non-determinism error captured during job application (e.g. a
    # ResolveActivity for an unknown seq). Job application cannot simply die
    # because the dynamically-scoped $CURRENT teardown and the completion build
    # must still run; instead the error is stashed here and the decision table
    # routes it (task-fail by default, workflow-fail when configured — T-wf-13).
    field $nondeterminism_error;

    # A workflow TASK failure detected while applying a job (spec section 19.2):
    # a read-only-context violation by a validator (a validator that issued a
    # command or otherwise tried to mutate state). Unlike a non-determinism
    # error this is recorded synchronously inside _apply_do_update and routed by
    # the outcome decision table as a task failure. Only the first is kept.
    field $current_activation_error;

    # Read-only guard depth (spec section 19.2 / sdk-python _as_read_only):
    # while > 0 the runner is executing a synchronous read-only block (an update
    # validator), so any command-emitting call (_emit_command) MUST throw rather
    # than buffer a command. A counter (not a bool) so nesting is safe.
    field $read_only_depth = 0;

    # DoUpdate jobs delivered before the instance exists (spec section 19.2):
    # an update arriving in the init activation (ordered before
    # InitializeWorkflow) has no instance to dispatch against yet, so it is
    # buffered here in arrival order and re-applied right after _apply_initialize
    # creates the instance (mirrors %buffered_signals, but updates are NEVER
    # buffered for a missing handler — only for a missing instance).
    field @buffered_updates;

    # Signals delivered before a matching handler exists (spec section 10.3
    # T-wf-3 QUEUEING; MUST-match sdk-python self._buffered_signals): a hash
    # keyed by signal name -> arrayref of SignalWorkflow jobs awaiting a handler.
    # Signals routed here include those arriving before the instance is created
    # (the named/dynamic handler is a METHOD on the instance) and those whose
    # name has no named handler and no dynamic handler. They are drained, in
    # arrival order, once a matching handler becomes available (after
    # InitializeWorkflow creates the instance, or for a later-registered dynamic
    # handler). Workflow-scoped (persists across activations until drained).
    field %buffered_signals;

    # In-progress signal-handler Futures (spec section 10.3 ASYNC HANDLER
    # TRACKING; MUST-match sdk-python self._in_progress_signals): a hash keyed by
    # a monotonic handler id -> the handler's Future. An async :Signal handler
    # may await timers/activities; its Future is tracked here and pumped like any
    # other workflow Future. The workflow is NOT considered complete while any
    # handler Future is still pending — _all_handlers_finished gates
    # CompleteWorkflowExecution. The id is removed when the handler Future
    # becomes ready.
    field %in_progress_handlers;
    field $handler_seq = 0;   # monotonic handler id source.

    # Pending wait_condition predicates (spec section 10.2 wait_condition /
    # T-wf-5; MUST-match sdk-python self._conditions — a list of (predicate,
    # future) pairs). Each entry is a hashref { predicate => sub, future =>
    # Workflow::Future, timer => Workflow::Future|undef }. The predicates are
    # RE-CHECKED after each job set is applied (the pump): one whose predicate
    # is now true has its future resolved (->done) and is removed; the rest stay
    # pending across activations. A predicate must be deterministic and
    # side-effect-free (it is re-run every pump and reads workflow state only).
    # A timeout-bearing wait also starts a timer (separate timer seq space) and
    # races it: if the timer fires first the wait future is failed with a
    # Temporalio::Exception::Timeout (sdk-python asyncio.wait_for).
    field @conditions;

    # In-workflow search-attribute / memo views (spec section 24). Seeded from the
    # InitializeWorkflow job's start-time search_attributes / memo, then kept in
    # sync as upsert_search_attributes / upsert_memo run. Each is a name -> Perl
    # value map (an unset/removed key is deleted from the map). Surfaced through
    # info->{search_attributes} / info->{memo} (NOT BinaryChecksums). Workflow-
    # scoped, persisting across activations.
    field %search_attributes_view;
    field %memo_view;

    ADJUST {
        $payload_converter //= Temporalio::Converter::Payload->default;
        $failure_converter //= Temporalio::Converter::Failure->default;
        # Lazily load the workflow class if the caller has not already (the
        # replay harness accepts a class name without requiring it first).
        if (!$workflow_class->can('_workflow_type')) {
            my $path = ($workflow_class =~ s{::}{/}gr) . '.pm';
            require $path;
        }
        $workflow_type = $workflow_class->_workflow_type;
    }

    # --- context accessors read by the Temporalio::Workflow:: functions ------

    method run_id        { return $run_id }
    method workflow_type { return $workflow_type }
    method is_replaying  { return $is_replaying ? 1 : 0 }

    # Epoch seconds (float) of the activation timestamp.
    method activation_time {
        return $activation_seconds + ($activation_nanos / 1_000_000_000);
    }

    method random { return $rng }

    # The replay-aware workflow logger (spec section 10.4). Built once per run,
    # bound to this runner so its is_replaying gate tracks the live activation.
    method logger {
        $logger //= Temporalio::Workflow::Logger->new(runner => $self);
        return $logger;
    }

    method info {
        return {
            run_id        => $run_id,
            workflow_type => $workflow_type,
            # The workflow namespace (spec section 20): read by
            # get_external_workflow_handle to populate the
            # NamespacedWorkflowExecution arm of signal/cancel commands.
            namespace     => $namespace,
            # The patch ids the server has notified for this run (spec section
            # 10.3 "record in workflow info"). Sorted for a stable view.
            patches       => [ sort keys %patches_notified ],
            # The in-workflow search-attribute / memo views (spec section 24),
            # seeded from start-time values and kept in sync by upsert_*. Copied
            # so callers cannot mutate the runner's view through info.
            search_attributes => { %search_attributes_view },
            memo              => { %memo_view },
        };
    }

    # patched($patch_id, deprecated => $bool) -> a boolean: should the workflow
    # take the "with change" branch? (spec section 10.4 versioning; MUST-match
    # sdk-python workflow_patch). The answer is memoized per run so it is stable
    # and the SetPatchMarker is emitted at most once. On a fresh (non-replay)
    # execution the patch is always in use; during replay it is in use only when
    # the server notified it (it was present in history). Emitting the marker
    # tells the server this run took the patched branch.
    method patched ($patch_id, %opts) {
        my $deprecated = $opts{deprecated} ? 1 : 0;

        # A previously-memoized answer wins (even when deprecating, we keep the
        # memoized result and skip re-emitting the command — sdk-python parity).
        if (exists $patches_memoized{$patch_id}) {
            return $patches_memoized{$patch_id};
        }

        my $use_patch = (!$is_replaying || exists $patches_notified{$patch_id})
            ? 1 : 0;
        $patches_memoized{$patch_id} = $use_patch;

        if ($use_patch) {
            push @commands,
                Temporalio::Workflow::Commands::set_patch_marker(
                    $patch_id, $deprecated);
        }
        return $use_patch;
    }

    # --- activity scheduling (spec section 10.2 / 10.3) ----------------------

    # schedule_activity(%opts) -> a Temporalio::Workflow::Future resolved when
    # the matching ResolveActivity job arrives. Allocates the next seq, builds
    # the ScheduleActivity command, buffers it, and registers the pending
    # Future. The Workflow:: functional surface (execute_activity/start_activity)
    # delegates here. %opts mirrors the spec section 10.2 kwargs:
    #   activity_type (required), args (arrayref), task_queue, activity_id,
    #   schedule_to_close_timeout, schedule_to_start_timeout,
    #   start_to_close_timeout, heartbeat_timeout (all seconds), retry_policy
    #   (Temporalio::Common::RetryPolicy), cancellation_type (string), headers.
    method schedule_activity (%opts) {
        $self->_assert_writable('execute_activity/start_activity');
        my $activity_type = $opts{activity_type}
            // die "Temporalio::Workflow::Runner: schedule_activity needs an "
                 . "activity_type";

        my $seq = ++$activity_seq_counter;  # activity seq space, from 1.

        # Convert the activity arguments to payloads (MUST-match sdk-python:
        # arguments converted before the command is built so a converter error
        # surfaces at the call site, not later).
        my @args = map { $payload_converter->to_payload($_) }
            (($opts{args} // [])->@*);

        my %fields = (
            seq           => $seq,
            # activity_id defaults to the seq as a string (sdk-python parity).
            activity_id   => (defined $opts{activity_id}
                ? $opts{activity_id} : "$seq"),
            activity_type => $activity_type,
            # task_queue defaults to the workflow's own queue (sdk-python parity);
            # the replay harness has no queue, so default to empty string.
            task_queue    => ($opts{task_queue} // $task_queue // ''),
            (@args ? (arguments => [@args]) : ()),
            # cancellation_type: spec string -> proto enum number (default
            # try_cancel = 0).
            cancellation_type =>
                _cancellation_type_number($opts{cancellation_type}),
            # Eager activity dispatch (spec section 23.2): suppress eager
            # execution on this activity when the worker disabled it. Defaults to
            # false (eager allowed); MUST-match sdk-python do_not_eagerly_execute.
            ($disable_eager_activity_execution
                ? (do_not_eagerly_execute => 1) : ()),
        );

        # The four timeouts: seconds -> google.protobuf.Duration, only when set.
        for my $t (qw(schedule_to_close_timeout schedule_to_start_timeout
            start_to_close_timeout heartbeat_timeout))
        {
            next unless defined $opts{$t};
            $fields{$t} = _duration($opts{$t});
        }

        # Retry policy -> temporal.api.common.v1.RetryPolicy proto when given.
        if (defined(my $rp = $opts{retry_policy})) {
            $fields{retry_policy} = $rp->to_proto;
        }

        # Headers: { name => Perl value } -> { name => Payload } when non-empty.
        if (my $headers = $opts{headers}) {
            if (%$headers) {
                $fields{headers} = {
                    map { $_ => $payload_converter->to_payload($headers->{$_}) }
                        keys %$headers
                };
            }
        }

        push @commands,
            Temporalio::Workflow::Commands::schedule_activity(\%fields);

        # ABANDON (ActivityCancellationType=2): on cancel, the workflow stops
        # waiting WITHOUT asking core to cancel the activity — so the Future's
        # cancel emits NO RequestCancelActivity (proto comment: "Do not request
        # cancellation of the activity and immediately report cancellation to
        # the workflow"). TRY_CANCEL (0) / WAIT_CANCELLATION_COMPLETED (1) emit
        # RequestCancelActivity so core forwards the cancel to the running
        # activity (MUST-match sdk-python _ActivityHandle._apply_cancel_command).
        my $is_abandon = $fields{cancellation_type} == 2 ? 1 : 0;

        # Register the pending Future the body awaits; the runner resolves it
        # imperatively from the ResolveActivity job (never via IO::Async). The
        # _ActivityFuture cancel hook emits RequestCancelActivity (unless
        # abandon), records the seq as cancelled (so a later stale
        # ResolveActivity{cancelled} from core is tolerated, not flagged as
        # non-determinism), de-registers the pending entry, and fails the Future
        # with Cancelled — the await raises Cancelled in the same activation.
        my $future = Temporalio::Workflow::Runner::_ActivityFuture->_new_activity(
            seq       => $seq,
            on_cancel => sub {
                return unless delete $pending_activities{$seq};
                $cancelled_activity_seqs{$seq} = 1;
                push @commands,
                    Temporalio::Workflow::Commands::request_cancel_activity($seq)
                    unless $is_abandon;
            },
        );
        $pending_activities{$seq} = $future;
        return $future;
    }

    # --- local activities (spec section 21) ----------------------------------

    # schedule_local_activity(%opts) -> a Temporalio::Workflow::Future resolved
    # on the LA's terminal ResolveActivity (completed/failed/cancelled). The
    # local-activity analog of schedule_activity: it allocates from the SAME
    # activity seq space (++$activity_seq_counter) and registers in the SAME
    # %pending_activities map, so LA and regular handles never collide (mirrors
    # sdk-python). It emits a ScheduleLocalActivity command (no task_queue /
    # heartbeat_timeout / priority — core runs the LA in-process). %opts mirrors
    # the spec section 21.1 kwargs: activity_type (required), args (arrayref),
    # schedule_to_close_timeout, schedule_to_start_timeout, start_to_close_timeout
    # (seconds), retry_policy, local_retry_threshold (seconds, default 60),
    # cancellation_type (default try_cancel), activity_id, summary, headers.
    #
    # The backoff -> server-timer -> re-schedule loop is RUNNER-OWNED (spec
    # decision D1): the returned Future is a single stable OUTER future, resolved
    # only on a terminal outcome. A `backoff` resolution does NOT touch it — the
    # runner starts a timer and re-schedules under a new seq when it fires. The
    # per-LA state needed to re-schedule lives in %local_activity_state.
    method schedule_local_activity (%opts) {
        $self->_assert_writable('execute_local_activity/start_local_activity');
        my $activity_type = $opts{activity_type}
            // die "Temporalio::Workflow::Runner: schedule_local_activity needs "
                 . "an activity_type";

        # Convert arguments up front so a converter error surfaces at the call
        # site (parity with schedule_activity), and convert headers / summary.
        my @args = map { $payload_converter->to_payload($_) }
            (($opts{args} // [])->@*);

        # local_retry_threshold defaults to 60s (spec section 21.1; proto comment
        # "Defaults to 1 minute").
        my $threshold = defined $opts{local_retry_threshold}
            ? $opts{local_retry_threshold} : 60;

        # The reusable field set (everything EXCEPT seq and the backoff-only
        # attempt/original_schedule_time). A backoff re-schedule reuses this.
        my %base = (
            activity_type     => $activity_type,
            (@args ? (arguments => [@args]) : ()),
            cancellation_type =>
                _cancellation_type_number($opts{cancellation_type}),
            local_retry_threshold => _duration($threshold),
        );

        # The three LA timeouts (NO heartbeat_timeout — LAs do not heartbeat at
        # the lang level): seconds -> Duration, only when set.
        for my $t (qw(schedule_to_close_timeout schedule_to_start_timeout
            start_to_close_timeout))
        {
            next unless defined $opts{$t};
            $base{$t} = _duration($opts{$t});
        }

        if (defined(my $rp = $opts{retry_policy})) {
            $base{retry_policy} = $rp->to_proto;
        }

        if (my $headers = $opts{headers}) {
            if (%$headers) {
                $base{headers} = {
                    map { $_ => $payload_converter->to_payload($headers->{$_}) }
                        keys %$headers
                };
            }
        }

        my $summary = defined $opts{summary}
            ? $payload_converter->to_payload($opts{summary}) : undef;

        my $seq = ++$activity_seq_counter;   # SHARED activity seq space.

        my $is_abandon = $base{cancellation_type} == 2 ? 1 : 0;

        # The single stable outer Future the body awaits. Its cancel hook honours
        # the cancellation_type (spec section 21.2): try_cancel/abandon resolve
        # Cancelled now (try_cancel also emits RequestCancelLocalActivity);
        # wait_cancellation_completed emits the cancel but PARKS (the future is
        # resolved only by the later ResolveActivity{cancelled}). A backing-off
        # LA cancels its pending backoff timer instead (CancelTimer).
        my $future =
            Temporalio::Workflow::Runner::_LocalActivityFuture->_new_local(
                seq        => $seq,
                runner     => $self,
                is_abandon => $is_abandon,
                wait       => ($base{cancellation_type} == 1 ? 1 : 0),
            );

        $local_activity_state{$seq} = {
            future            => $future,
            base              => \%base,
            summary           => $summary,
            activity_id       => $opts{activity_id},
        };
        $pending_activities{$seq} = $future;

        $self->_emit_schedule_local_activity($seq);
        return $future;
    }

    # _emit_schedule_local_activity($seq, %extra) — build and buffer the
    # ScheduleLocalActivity command for the LA tracked under $seq. %extra carries
    # the backoff-only fields on a re-schedule (attempt, original_schedule_time);
    # a fresh schedule passes none. activity_id defaults to the CURRENT seq as a
    # string (so a backoff re-schedule gets the new seq's id) unless the caller
    # set an explicit activity_id.
    method _emit_schedule_local_activity ($seq, %extra) {
        my $state = $local_activity_state{$seq}
            // die "Temporalio::Workflow::Runner: no LA state for seq $seq";
        my %fields = (
            seq         => $seq,
            activity_id => (defined $state->{activity_id}
                ? $state->{activity_id} : "$seq"),
            $state->{base}->%*,
            %extra,
        );
        push @commands, Temporalio::Workflow::Commands::schedule_local_activity(
            \%fields, $state->{summary});
        return;
    }

    # _on_local_activity_cancel($future, $seq, $is_abandon, $wait) — the runner
    # side of a local activity's Future ->cancel (spec section 21.2). Returns
    # true when the caller (the _LocalActivityFuture) should resolve Cancelled
    # IMMEDIATELY, or false when it should PARK (wait_cancellation_completed: the
    # cancel command is emitted now, but the outer future stays pending until the
    # eventual ResolveActivity{cancelled}). $future is the outer future itself,
    # used to detect a backing-off LA by identity (its state is stashed on the
    # backoff timer entry, not in %local_activity_state, while backing off).
    #
    # Three cases by current LA position:
    #   * Backing off (pending backoff timer holds this future's state): cancel
    #     the timer (CancelTimer), drop the re-schedule, resolve Cancelled now,
    #     regardless of cancellation_type — no running activity to wait for
    #     (T-local-13).
    #   * In-flight, abandon: emit NO command; resolve Cancelled now (T-local-12).
    #   * In-flight, try_cancel/wait: emit RequestCancelLocalActivity; try_cancel
    #     resolves now (T-local-10), wait parks (T-local-11).
    method _on_local_activity_cancel ($future, $seq, $is_abandon, $wait) {
        # Backing off? A backoff-timer entry whose stashed state's future is THIS
        # future means the LA is parked on its server timer.
        for my $tseq (keys %local_activity_backoff_timers) {
            my $info = $local_activity_backoff_timers{$tseq};
            next unless ($info->{state}{future} // 0) == $future;
            delete $local_activity_backoff_timers{$tseq};   # drop re-schedule.
            my $timer = $pending_timers{$tseq};
            $timer->cancel if defined $timer && !$timer->is_ready; # CancelTimer.
            return 1;   # resolve Cancelled now.
        }

        # In-flight. wait_cancellation_completed PARKS: emit the cancel command,
        # leave the LA registered (so the later ResolveActivity{cancelled} is
        # matched, not flagged unknown), and tell the future to stay pending.
        if ($wait && !$is_abandon) {
            push @commands,
                Temporalio::Workflow::Commands::request_cancel_local_activity(
                    $seq);
            return 0;
        }

        # try_cancel / abandon: de-register and resolve Cancelled now. try_cancel
        # emits RequestCancelLocalActivity and records the cancelled seq so a
        # later stale ResolveActivity{cancelled} from core is tolerated; abandon
        # emits no command.
        delete $local_activity_state{$seq};
        delete $pending_activities{$seq};
        unless ($is_abandon) {
            $cancelled_activity_seqs{$seq} = 1;
            push @commands,
                Temporalio::Workflow::Commands::request_cancel_local_activity(
                    $seq);
        }
        return 1;
    }

    # _force_local_activity_cancel($seq, $is_abandon) — the runner side of the
    # whole-workflow cancel chain for an IN-FLIGHT LA (spec section 10.3): emit
    # RequestCancelLocalActivity (unless abandon), record the cancelled seq, and
    # de-register. The future itself is failed Cancelled by the caller. (Backing-
    # off LAs are handled separately in _apply_cancel_workflow.)
    method _force_local_activity_cancel ($seq, $is_abandon) {
        delete $local_activity_state{$seq};
        delete $pending_activities{$seq};
        unless ($is_abandon) {
            $cancelled_activity_seqs{$seq} = 1;
            push @commands,
                Temporalio::Workflow::Commands::request_cancel_local_activity(
                    $seq);
        }
        return;
    }

    # --- child workflows (spec section 18) -----------------------------------

    # start_child_workflow(workflow_type => ..., %opts) -> the start
    # Temporalio::Workflow::Future (->done with the ChildWorkflowHandle once
    # ResolveChildWorkflowExecutionStart{succeeded} arrives). Allocates a CHILD
    # seq (separate space), converts args/memo/headers/timeouts BEFORE building
    # the command (so converter errors surface at the call site), resolves the
    # id/task_queue/enums, buffers a StartChildWorkflowExecution command, and
    # registers a handle wrapping a start Future and a result Future in
    # %pending_child_workflows{$seq}. %opts mirrors spec section 18.1:
    #   workflow_type (required), args (arrayref), id, task_queue,
    #   cancellation_type, parent_close_policy, id_reuse_policy,
    #   execution_timeout, run_timeout, task_timeout (all seconds),
    #   retry_policy (Temporalio::Common::RetryPolicy), cron_schedule, memo,
    #   search_attributes, headers.
    method start_child_workflow (%opts) {
        $self->_assert_writable('start_child_workflow/execute_child_workflow');
        my $workflow_type = $opts{workflow_type}
            // die "Temporalio::Workflow::Runner: start_child_workflow needs a "
                 . "workflow_type";

        my $seq = ++$child_workflow_seq_counter;  # child seq space, from 1.

        # id defaults to a DETERMINISTIC RNG-derived value (spec section 18.1):
        # never rand/OS entropy, so replay reproduces it. _default_child_id
        # draws from the workflow RNG.
        my $id = defined $opts{id} ? $opts{id} : $self->_default_child_id;

        # Convert child arguments to payloads up front (parity with
        # schedule_activity: a converter error must surface at the call site).
        my @input = map { $payload_converter->to_payload($_) }
            (($opts{args} // [])->@*);

        my %fields = (
            seq           => $seq,
            workflow_id   => $id,
            workflow_type => $workflow_type,
            # task_queue defaults to the parent workflow's queue (spec section
            # 18.1). The replay harness has no queue, so default to empty string.
            task_queue    => ($opts{task_queue} // $task_queue // ''),
            (@input ? (input => [@input]) : ()),
            # The three enums: spec string -> proto enum number, with the
            # spec section 18.1 defaults (NOT the proto zero values).
            cancellation_type   =>
                _child_cancellation_type_number($opts{cancellation_type}),
            parent_close_policy =>
                _parent_close_policy_number($opts{parent_close_policy}),
            workflow_id_reuse_policy =>
                _id_reuse_policy_number($opts{id_reuse_policy}),
        );

        # The three timeouts: seconds -> google.protobuf.Duration, only when set.
        my %timeout_field = (
            execution_timeout => 'workflow_execution_timeout',
            run_timeout       => 'workflow_run_timeout',
            task_timeout      => 'workflow_task_timeout',
        );
        for my $opt (keys %timeout_field) {
            next unless defined $opts{$opt};
            $fields{ $timeout_field{$opt} } = _duration($opts{$opt});
        }

        # cron_schedule is a plain string field when given.
        if (defined $opts{cron_schedule}) {
            $fields{cron_schedule} = $opts{cron_schedule};
        }

        # Retry policy -> temporal.api.common.v1.RetryPolicy proto when given.
        if (defined(my $rp = $opts{retry_policy})) {
            $fields{retry_policy} = $rp->to_proto;
        }

        # Headers / memo: { name => Perl value } -> { name => Payload } when set.
        for my $map (qw(headers memo)) {
            my $h = $opts{$map};
            next unless $h && %$h;
            $fields{$map} = {
                map { $_ => $payload_converter->to_payload($h->{$_}) } keys %$h
            };
        }

        # Search attributes -> proto when given (the value already exposes
        # to_proto, mirroring the start_workflow request builder).
        if (defined(my $sa = $opts{search_attributes})) {
            $fields{search_attributes} = $sa->can('to_proto')
                ? $sa->to_proto : $sa;
        }

        push @commands,
            Temporalio::Workflow::Commands::start_child_workflow_execution(
                \%fields);

        # The cancellation_type governs cancel behaviour (spec section 18.2,
        # MUST-match the ChildWorkflowCancellationType proto semantics):
        #   abandon (0): emit NO cancel command; stop waiting immediately
        #     (fail the pending awaits with Cancelled now).
        #   try_cancel (1): emit the cancel command AND immediately report
        #     cancellation to the parent (fail the pending awaits now).
        #   wait_cancellation_completed (2) / wait_cancellation_requested (3):
        #     emit the cancel command but stay parked on `result` — the body
        #     observes cancellation only when the later cancelled resolve
        #     arrives (do NOT pre-emptively fail the awaits).
        my $ct        = $fields{cancellation_type};
        my $is_abandon = $ct == 0 ? 1 : 0;
        my $report_now = ($ct == 0 || $ct == 1) ? 1 : 0;
        my $cancel_emitted = 0;   # emit the cancel command at most once.

        my $start_future  = Temporalio::Workflow::Future->new;
        my $result_future = Temporalio::Workflow::Future->new;

        require Temporalio::Workflow::ChildWorkflowHandle;
        my $handle = Temporalio::Workflow::ChildWorkflowHandle->new(
            id                 => $id,
            child_workflow_seq => $seq,
            start_future       => $start_future,
            result_future      => $result_future,
            # cancel hook: emit CancelChildWorkflowExecution (unless abandon),
            # then either fail the pending awaits now (abandon / try_cancel) or
            # stay parked until the cancelled resolve (wait_* types). Under the
            # wait_* types the seq STAYS mapped so the later
            # ResolveChildWorkflowExecution{cancelled} settles it.
            on_cancel => sub ($h) {
                return unless exists $pending_child_workflows{$seq};
                if (!$is_abandon && !$cancel_emitted) {
                    push @commands,
                        Temporalio::Workflow::Commands::cancel_child_workflow_execution(
                            $seq);
                    $cancel_emitted = 1;
                }
                return unless $report_now;
                delete $pending_child_workflows{$seq};
                for my $f ($start_future, $result_future) {
                    next if $f->is_ready;
                    $f->fail(Temporalio::Exception::Cancelled->new(
                        message => 'Child workflow cancelled',
                    ));
                }
            },
            # signal hook: emit a SignalExternalWorkflowExecution on the
            # child_workflow_id arm and register a pending signal Future.
            on_signal => sub ($h, $name, %sig_opts) {
                return $self->_signal_child_workflow($h, $name, %sig_opts);
            },
        );

        $pending_child_workflows{$seq} = $handle;
        return $start_future;
    }

    # Emit a SignalExternalWorkflowExecution targeting a child (spec section 18;
    # child_workflow_id oneof arm) and register the pending signal Future so a
    # later ResolveSignalExternalWorkflow settles it. Returns the Future the
    # $handle->signal caller awaits.
    method _signal_child_workflow ($handle, $name, %opts) {
        my $seq = ++$external_signal_seq_counter;

        my @args = map { $payload_converter->to_payload($_) }
            (($opts{args} // [])->@*);

        my %fields = (
            seq               => $seq,
            child_workflow_id => $handle->id,
            signal_name       => $name,
            (@args ? (args => [@args]) : ()),
        );
        if (my $h = $opts{headers}) {
            if (%$h) {
                $fields{headers} = {
                    map { $_ => $payload_converter->to_payload($h->{$_}) }
                        keys %$h
                };
            }
        }

        push @commands,
            Temporalio::Workflow::Commands::signal_external_workflow_execution(
                \%fields);

        my $future = Temporalio::Workflow::Future->new;
        $pending_external_signals{$seq} = $future;
        return $future;
    }

    # --- external workflow handles (spec section 20) -------------------------

    # get_external_workflow_handle($workflow_id, %opts) -> a
    # Temporalio::Workflow::ExternalWorkflowHandle. A synchronous, non-command
    # constructor (spec section 20.1): it captures the target id/run_id plus the
    # runner reference and emits nothing. %opts: run_id (undef targets the most
    # recent run). The handle's signal/cancel methods delegate back to the two
    # methods below.
    method get_external_workflow_handle ($workflow_id, %opts) {
        require Temporalio::Workflow::ExternalWorkflowHandle;
        return Temporalio::Workflow::ExternalWorkflowHandle->new(
            workflow_id => $workflow_id,
            run_id      => $opts{run_id},
            runner      => $self,
        );
    }

    # Emit a SignalExternalWorkflowExecution targeting an arbitrary workflow
    # (spec section 20; the workflow_execution oneof arm, NOT child_workflow_id)
    # and register the pending signal Future so a later
    # ResolveSignalExternalWorkflow settles it. The namespace comes from this
    # runner's namespace (never a user argument). Cancelling the returned Future
    # before its resolve emits CancelSignalWorkflow{seq} and does NOT
    # pre-emptively settle it — the eventual Resolve* still arrives (spec section
    # 20.2 in-flight cancellation; MUST-match sdk-python asyncio.shield +
    # cancel_signal_workflow). Returns the Future the $handle->signal caller awaits.
    method _signal_external_workflow ($workflow_id, $run_id, $name, %opts) {
        my $seq = ++$external_signal_seq_counter;

        my @args = map { $payload_converter->to_payload($_) }
            (($opts{args} // [])->@*);

        my %fields = (
            seq                => $seq,
            workflow_execution => {
                namespace   => $namespace,
                workflow_id => $workflow_id,
                run_id      => ($run_id // ''),
            },
            signal_name        => $name,
            (@args ? (args => [@args]) : ()),
        );
        if (my $h = $opts{headers}) {
            if (%$h) {
                $fields{headers} = {
                    map { $_ => $payload_converter->to_payload($h->{$_}) }
                        keys %$h
                };
            }
        }

        push @commands,
            Temporalio::Workflow::Commands::signal_external_workflow_execution(
                \%fields);

        my $future = Temporalio::Workflow::Future->new;
        $pending_external_signals{$seq} = $future;

        # In-flight cancellation (spec section 20.2): if the awaiting frame is
        # cancelled before the resolve, emit CancelSignalWorkflow{seq} but leave
        # the seq mapped so the eventual ResolveSignalExternalWorkflow settles
        # it. The hook must NOT fail the Future here (cancelling a Future already
        # marks it ready/cancelled); we only emit the cancel command at most once.
        my $cancel_emitted = 0;
        $future->on_cancel(sub {
            return if $cancel_emitted;
            $cancel_emitted = 1;
            push @commands,
                Temporalio::Workflow::Commands::cancel_signal_workflow($seq);
        });

        return $future;
    }

    # Emit a RequestCancelExternalWorkflowExecution targeting an arbitrary
    # workflow (spec section 20) and register the pending cancel Future so a
    # later ResolveRequestCancelExternalWorkflow settles it. Draws from the
    # SEPARATE external-cancel seq space. A cancel request has no counter-cancel
    # ("there is no cancelling a cancel request" — spec section 20.2), so no
    # on_cancel hook is installed. Returns the Future the $handle->cancel caller
    # awaits.
    method _request_cancel_external_workflow ($workflow_id, $run_id, %opts) {
        my $seq = ++$external_cancel_seq_counter;

        my %fields = (
            seq                => $seq,
            workflow_execution => {
                namespace   => $namespace,
                workflow_id => $workflow_id,
                run_id      => ($run_id // ''),
            },
        );

        push @commands,
            Temporalio::Workflow::Commands::request_cancel_external_workflow_execution(
                \%fields);

        my $future = Temporalio::Workflow::Future->new;
        $pending_external_cancels{$seq} = $future;
        return $future;
    }

    # A deterministic default child workflow id (spec section 18.1): a UUIDish
    # string derived from the workflow RNG (never rand/OS entropy), so replay
    # reproduces it. Uses the same ISAAC generator that backs
    # Temporalio::Workflow::random; draws are deterministic per the run's seed.
    method _default_child_id {
        my @hex = map { sprintf '%08x', $rng->irand } 1 .. 4;
        my $h = join '', @hex;   # 32 hex chars.
        # Format as a UUID-shaped string (8-4-4-4-12) for readability/parity.
        return join '-',
            substr($h, 0, 8),  substr($h, 8, 4),  substr($h, 12, 4),
            substr($h, 16, 4), substr($h, 20, 12);
    }

    # --- timers (spec section 10.2 start_timer/sleep + 10.3 FireTimer) -------

    # start_timer($seconds) -> a Temporalio::Workflow::Future resolved when the
    # matching FireTimer job arrives. Allocates the next TIMER seq (a seq space
    # separate from activities — sdk-python _next_seq("timer") / sdk-ruby
    # @timer_counter), builds the StartTimer command, buffers it, and registers
    # the pending Future. Cancelling the returned Future emits a CancelTimer
    # command (same seq) and resolves the Future as Temporalio::Exception::
    # Cancelled (MUST-match sdk-ruby _apply_cancel_command / CanceledError).
    method start_timer ($seconds) {
        $self->_assert_writable('start_timer/sleep');
        my $seq = ++$timer_seq_counter;   # timer seq space, from 1.

        push @commands, Temporalio::Workflow::Commands::start_timer({
            seq                   => $seq,
            start_to_fire_timeout => _duration($seconds),
        });

        # A timer future whose ->cancel FAILS the future with a
        # Temporalio::Exception::Cancelled (rather than putting it into Future's
        # native cancelled state). The reference SDKs raise a cancellation
        # *exception* into the awaiting frame (sdk-ruby fiber.raise(CanceledError);
        # sdk-python cancels the asyncio task which surfaces CancelledError) — a
        # natively-cancelled CPAN Future would instead make `await` throw a bare
        # "was cancelled" string, losing the Temporal exception identity. The
        # cancel also emits the CancelTimer command (same seq) and de-registers
        # the pending timer so a later FireTimer for it is a no-op.
        my $future = Temporalio::Workflow::Runner::_TimerFuture->_new_timer(
            seq        => $seq,
            on_cancel  => sub {
                return unless delete $pending_timers{$seq};
                push @commands,
                    Temporalio::Workflow::Commands::cancel_timer($seq);
            },
        );
        $pending_timers{$seq} = $future;
        return $future;
    }

    # --- upsert search attributes & memo (spec section 24) ------------------

    # upsert_search_attributes(@updates) -> emit an UpsertWorkflowSearchAttributes
    # command (oneof tag 18; MUST-match sdk-python
    # workflow_upsert_search_attributes). @updates are
    # Temporalio::Common::SearchAttributeUpdate objects (typed-only: an untyped
    # mapping raises Temporalio::Exception::Argument — the resolved decision to
    # reject the Python-deprecated overload). Empty @updates early-return with no
    # command. Every value is converted BEFORE the command is buffered so a
    # conversion failure leaves no partial command (a value_set encodes via the
    # key's encode_value carrying the typed SA metadata; a value_unset writes a
    # proper null Payload — no type metadata, the server-side deletion
    # convention). The info->{search_attributes} view is updated in place.
    method upsert_search_attributes (@updates) {
        $self->_assert_writable('upsert_search_attributes');

        for my $u (@updates) {
            unless (Scalar::Util::blessed($u)
                && $u->isa('Temporalio::Common::SearchAttributeUpdate')) {
                Temporalio::Exception::Argument->throw(message =>
                    'upsert_search_attributes accepts only typed updates built '
                    . 'via $key->value_set / $key->value_unset (an untyped '
                    . 'mapping is rejected — spec section 24)');
            }
        }
        return unless @updates;   # empty -> no command (spec section 24.2).

        # Convert first (no partial command on failure). Track the post-update
        # view edits separately so they only land once every value encodes.
        my %indexed_fields;
        my @view_edits;
        for my $u (@updates) {
            my $key = $u->key;
            if ($u->is_unset) {
                $indexed_fields{ $key->name } =
                    $payload_converter->to_payload(undef);
                push @view_edits, [ $key->name, undef ];   # undef -> delete.
            }
            else {
                $indexed_fields{ $key->name } = $key->encode_value($u->value);
                push @view_edits, [ $key->name, $u->value ];
            }
        }

        my $SearchAttributes = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.SearchAttributes');
        push @commands,
            Temporalio::Workflow::Commands::upsert_workflow_search_attributes(
                $SearchAttributes->new({ indexed_fields => \%indexed_fields }));

        for my $edit (@view_edits) {
            my ($name, $value) = @$edit;
            if (defined $value) { $search_attributes_view{$name} = $value }
            else                { delete $search_attributes_view{$name} }
        }
        return;
    }

    # upsert_memo($updates) -> emit a ModifyWorkflowProperties command (oneof tag
    # 19; MUST-match sdk-python workflow_upsert_memo). $updates is a name -> value
    # hashref; an undef value REMOVES that key (an empty/null Payload — the
    # deletion convention; removals are emitted even for absent keys). Empty
    # $updates early-return with no command. Every non-removal value is converted
    # BEFORE the command is buffered so a conversion failure leaves no partial
    # command. The info->{memo} view is updated in place.
    method upsert_memo ($updates) {
        $self->_assert_writable('upsert_memo');
        $updates //= {};
        return unless keys %$updates;   # empty -> no command (spec section 24.2).

        # Convert first (no partial command on failure). A removal (undef value)
        # is a null Payload; a set is the converted value.
        my %fields;
        my @view_edits;
        for my $name (keys %$updates) {
            my $value = $updates->{$name};
            if (defined $value) {
                $fields{$name} = $payload_converter->to_payload($value);
                push @view_edits, [ $name, $value ];
            }
            else {
                $fields{$name} = $payload_converter->to_payload(undef);
                push @view_edits, [ $name, undef ];   # undef -> delete.
            }
        }

        my $Memo = Temporalio::Core::Proto::resolve('temporal.api.common.v1.Memo');
        push @commands,
            Temporalio::Workflow::Commands::modify_workflow_properties(
                $Memo->new({ fields => \%fields }));

        for my $edit (@view_edits) {
            my ($name, $value) = @$edit;
            if (defined $value) { $memo_view{$name} = $value }
            else                { delete $memo_view{$name} }
        }
        return;
    }

    # --- wait_condition (spec section 10.2 / T-wf-5) -------------------------

    # wait_condition($predicate, %opts) -> a Temporalio::Workflow::Future that
    # resolves (->done) once $predicate returns true. The predicate is
    # RE-CHECKED after each job set is applied (in _pump): when state mutated by
    # a signal/timer/activity resolution flips it true, the awaiting :Run
    # continuation resumes in that same activation. The predicate must be
    # deterministic and side-effect-free (it is re-run every pump and reads
    # workflow state only — it never commands). MUST-match sdk-python
    # workflow_wait_condition: append (fn, fut) to self._conditions; _run_once
    # re-checks each condition and resolves the future when fn() is true.
    #
    # %opts: timeout (seconds) optionally races the predicate against a timer.
    # If the timer fires before the predicate becomes true, the wait future is
    # failed with a Temporalio::Exception::Timeout (MUST-match sdk-python
    # asyncio.wait_for(fut, timeout) raising TimeoutError). When the predicate
    # wins first the timer is cancelled (emitting CancelTimer).
    method wait_condition ($predicate, %opts) {
        my $future = Temporalio::Workflow::Future->new;

        my $timer;
        if (defined $opts{timeout}) {
            $timer = $self->start_timer($opts{timeout});
            # If the timer fires (resolves done) before the predicate is
            # satisfied, the wait times out: fail the wait future with Timeout.
            # An already-resolved wait (predicate won) leaves this a no-op.
            $timer->on_done(sub {
                return if $future->is_ready;
                @conditions = grep { $_->{future} != $future } @conditions;
                $future->fail(Temporalio::Exception::Timeout->new(
                    message      => 'wait_condition timed out',
                    timeout_type => 'start_to_close',
                ));
            });
        }

        push @conditions, {
            predicate => $predicate,
            future    => $future,
            timer     => $timer,
        };

        # Re-check immediately: the predicate may already be true at call time
        # (sdk-python's _run_once re-checks conditions on the same loop tick).
        $self->_check_conditions;
        return $future;
    }

    # Re-check every pending wait_condition predicate (spec section 10.2 /
    # T-wf-5; MUST-match sdk-python _run_once's check_conditions pass). A
    # predicate that is now true resolves its future (->done) and the entry is
    # removed; the timer it raced (if any) is cancelled so no stale FireTimer
    # outlives the satisfied wait (emitting CancelTimer). Entries whose future
    # already resolved (e.g. a timed-out wait) are dropped. Predicates are
    # re-run as long as resolving one makes progress: a satisfied condition's
    # continuation may mutate state that satisfies another, so loop until a pass
    # resolves nothing (a fixpoint), mirroring sdk-python re-checking after the
    # ready queue drains.
    method _check_conditions {
        return unless @conditions;
        my $progressed = 1;
        while ($progressed) {
            $progressed = 0;
            my @still;
            for my $cond (@conditions) {
                my $future = $cond->{future};
                next if $future->is_ready;   # resolved (e.g. timed out): drop.
                if ($cond->{predicate}->()) {
                    # Predicate satisfied: cancel its timeout timer (if any) and
                    # resolve the wait. The continuation runs synchronously here.
                    my $timer = $cond->{timer};
                    $timer->cancel if defined $timer && !$timer->is_ready;
                    $future->done;
                    $progressed = 1;
                }
                else {
                    push @still, $cond;
                }
            }
            @conditions = @still;
        }
        return;
    }

    # --- activation processing (spec section 10.3) ---------------------------

    # process_activation($activation) -> the WorkflowActivationCompletion proto.
    method process_activation ($activation) {
        # Steps 1-2: activation context. (Step 3 job ordering + the full job
        # set land as later phases add job kinds; the skeleton handles
        # InitializeWorkflow and runs the body to completion.)
        $is_replaying = $activation->is_replaying ? 1 : 0;
        $run_id //= $activation->run_id;
        if (my $ts = $activation->timestamp) {
            $activation_seconds = $ts->seconds // 0;
            $activation_nanos   = $ts->nanos   // 0;
        }

        # The command buffer holds only THIS activation's commands: the worker
        # returns one completion per activation, so any commands emitted by a
        # prior activation have already been drained. The seq counter, by
        # contrast, is workflow-scoped and persists across activations.
        @commands = ();

        # Non-determinism is detected per-activation (it concerns the jobs in
        # THIS activation), so clear any prior detection. cancel_requested, by
        # contrast, is run-scoped and persists across activations.
        $nondeterminism_error = undef;

        # Step 3-5: order the jobs into the de-facto Temporal sets, apply each
        # set under the dynamically-scoped runner context (so the body's and the
        # handlers' Temporalio::Workflow:: calls resolve to this runner), and
        # pump after each set (spec section 10.3 step 3; MUST-match sdk-python's
        # four ordered job sets applied with a _run_once between them).
        #   (0) patch notifications, (1) signals (+ updates, Phase 4+),
        #   (2) all other non-query jobs (incl. InitializeWorkflow),
        #   (3) queries last.
        # Signals (set 1) run BEFORE InitializeWorkflow (set 2): a signal that
        # arrives in the init activation has no instance to dispatch against yet,
        # so _apply_signal_workflow buffers it; _apply_initialize then drains the
        # buffer once the instance exists (T-wf-3 visibility).
        dynamically $Temporalio::Workflow::Runner::CURRENT = $self;
        my $set_index = -1;
        for my $job_set ($self->_ordered_job_sets($activation)) {
            $set_index++;
            next unless @$job_set;
            $self->_apply_job($_) for @$job_set;
            # Re-check wait_condition predicates only after the signal set (1)
            # and the non-query set (2) — NOT after patches (0) or queries (3).
            # A query activation (incl. a standalone "legacy_query") must not
            # advance the workflow: resuming a parked :Run there would emit a
            # CompleteWorkflow alongside the QueryResult, which core rejects
            # ("legacy query response along with other commands"). MUST-match
            # sdk-python activate(): _run_once(check_conditions=index==1 or 2).
            $self->_pump(check_conditions => ($set_index == 1 || $set_index == 2));
        }

        # Steps 6-7: drain the command buffer into a completion proto.
        return $self->_build_completion;
    }

    # evict (spec section 10.3 RemoveFromCache): tear the runner down. Cancel
    # every pending activity/timer Future and the main run Future so no dangling
    # continuation survives the run's removal from the dispatcher cache. The
    # dispatcher drops the run_id -> runner mapping; no workflow code runs and an
    # empty successful completion is returned (the §8.3 eviction fast path).
    # MUST-match sdk-python _handle_cache_eviction (deletes the run from
    # _running_workflows after cancelling its tasks).
    method evict () {
        for my $future (values %pending_activities, values %pending_timers,
            values %in_progress_handlers, values %pending_external_signals,
            values %pending_external_cancels,
            map { $_->{future} } @conditions)
        {
            $future->cancel unless $future->is_ready;
        }
        # Child handles own a start AND a result Future; cancel both.
        for my $handle (values %pending_child_workflows) {
            for my $f ($handle->start_future, $handle->result_future) {
                $f->cancel unless $f->is_ready;
            }
        }
        %pending_activities             = ();
        %pending_timers                 = ();
        %local_activity_state           = ();
        %local_activity_backoff_timers  = ();
        %in_progress_handlers           = ();
        %pending_child_workflows        = ();
        %pending_external_signals       = ();
        %pending_external_cancels       = ();
        @conditions                     = ();
        if (defined $main_run_future && !$main_run_future->is_ready) {
            $main_run_future->cancel;
        }
        return;
    }

    method _apply_job ($job) {
        my $variant = $job->which_variant // '';
        if ($variant eq 'initialize_workflow') {
            return $self->_apply_initialize($job->initialize_workflow);
        }
        if ($variant eq 'resolve_activity') {
            return $self->_apply_resolve_activity($job->resolve_activity);
        }
        if ($variant eq 'fire_timer') {
            return $self->_apply_fire_timer($job->fire_timer);
        }
        if ($variant eq 'resolve_child_workflow_execution_start') {
            return $self->_apply_resolve_child_workflow_start(
                $job->resolve_child_workflow_execution_start);
        }
        if ($variant eq 'resolve_child_workflow_execution') {
            return $self->_apply_resolve_child_workflow(
                $job->resolve_child_workflow_execution);
        }
        if ($variant eq 'resolve_signal_external_workflow') {
            return $self->_apply_resolve_signal_external_workflow(
                $job->resolve_signal_external_workflow);
        }
        if ($variant eq 'resolve_request_cancel_external_workflow') {
            return $self->_apply_resolve_request_cancel_external_workflow(
                $job->resolve_request_cancel_external_workflow);
        }
        if ($variant eq 'cancel_workflow') {
            return $self->_apply_cancel_workflow($job->cancel_workflow);
        }
        if ($variant eq 'update_random_seed') {
            return $self->_apply_update_random_seed($job->update_random_seed);
        }
        if ($variant eq 'notify_has_patch') {
            return $self->_apply_notify_has_patch($job->notify_has_patch);
        }
        if ($variant eq 'signal_workflow') {
            return $self->_apply_signal_workflow($job->signal_workflow);
        }
        if ($variant eq 'query_workflow') {
            return $self->_apply_query_workflow($job->query_workflow);
        }
        if ($variant eq 'do_update') {
            return $self->_apply_do_update($job->do_update);
        }
        # RemoveFromCache (handled by the dispatcher fast path) and friends land
        # in later phases.
        warn "Temporalio::Workflow::Runner: ignoring unhandled activation job"
           . " variant '$variant'\n";
        return;
    }

    # Order an activation's jobs into the de-facto Temporal job sets (spec
    # section 10.3 step 3; MUST-match sdk-python activate()'s four sets). Each
    # returned arrayref is applied as a unit with a pump between sets. Within a
    # set, activation order is preserved.
    #   set 0: NotifyHasPatch
    #   set 1: SignalWorkflow + DoUpdate (spec section 19.2 — updates sort with
    #          signals, applied before InitializeWorkflow, in arrival order)
    #   set 2: every other non-query job (incl. InitializeWorkflow)
    #   set 3: QueryWorkflow (last; P4.2)
    method _ordered_job_sets ($activation) {
        my @sets = ([], [], [], []);
        for my $job ($activation->jobs->@*) {
            my $variant = $job->which_variant // '';
            if    ($variant eq 'notify_has_patch') { push $sets[0]->@*, $job }
            elsif ($variant eq 'signal_workflow')  { push $sets[1]->@*, $job }
            elsif ($variant eq 'do_update')        { push $sets[1]->@*, $job }
            elsif ($variant eq 'query_workflow')   { push $sets[3]->@*, $job }
            else                                   { push $sets[2]->@*, $job }
        }
        return @sets;
    }

    method _apply_initialize ($init) {
        # Seed the deterministic RNG from the job (NOT the run id).
        $rng = _make_rng($init->randomness_seed // 0);

        # Seed the in-workflow search-attribute / memo views from the start-time
        # values on the InitializeWorkflow job (spec section 24 / T-upsert-4). Each
        # payload is decoded to a Perl value; a null/empty payload decodes to undef
        # and is skipped (an unset key is simply absent from the view).
        if (defined(my $sa = $init->search_attributes)) {
            my $fields = $sa->indexed_fields // {};
            for my $name (keys %$fields) {
                my $value = $payload_converter->from_payload($fields->{$name});
                $search_attributes_view{$name} = $value if defined $value;
            }
        }
        if (defined(my $memo = $init->memo)) {
            my $fields = $memo->fields // {};
            for my $name (keys %$fields) {
                my $value = $payload_converter->from_payload($fields->{$name});
                $memo_view{$name} = $value if defined $value;
            }
        }

        # Convert the workflow arguments from payloads to Perl values.
        my @args = map { $payload_converter->from_payload($_) }
            ($init->arguments // [])->@*;

        # Instantiate the workflow class and kick off its :Run. The body runs
        # under the already-scoped $CURRENT (set in process_activation), so any
        # Temporalio::Workflow:: call inside it resolves to this runner. The
        # returned Future is pumped, not awaited synchronously.
        $instance = $workflow_class->new;
        my $run_ref = $workflow_class->_workflow_defs->{run};
        $main_run_future = $instance->$run_ref(@args);

        # Drain any signals buffered before the instance existed (spec section
        # 10.3 T-wf-3 QUEUEING; MUST-match sdk-python draining _buffered_signals
        # once a handler is available). The :Run body was just kicked off above,
        # so a drained signal handler's state mutation is visible to the run
        # continuation when it next makes progress.
        $self->_drain_buffered_signals;
        # Drain any updates buffered before the instance existed (spec section
        # 19.2): a DoUpdate ordered before InitializeWorkflow in the init
        # activation is dispatched here, after the buffered signals.
        $self->_drain_buffered_updates;
        return;
    }

    # ResolveActivity { seq, result } — resolve the pending activity Future for
    # this seq (spec section 10.3; MUST-match sdk-python _apply_resolve_activity).
    # ActivityResolution.status is a oneof: completed -> ->done(decoded result);
    # failed/cancelled -> ->fail(exception mapped from the Failure proto). The
    # awaiting workflow continuation runs synchronously at resolve time
    # (Future::AsyncAwait on_ready), so progress is observed in the pump.
    method _apply_resolve_activity ($job) {
        my $seq    = $job->seq;
        my $future = delete $pending_activities{$seq};
        unless (defined $future) {
            # A seq we already cancelled (its Future was failed Cancelled when
            # the cancel chain ran) gets a tolerated STALE ResolveActivity from
            # core afterwards — drop it, exactly as _apply_fire_timer drops a
            # stale FireTimer for a cancelled timer (spec section 10.3 cancel
            # chain / T-act-9). Not a non-determinism error.
            return if delete $cancelled_activity_seqs{$seq};

            # An unknown seq is a non-determinism error (spec section 10.3 /
            # T-wf-13): the activation references a command this workflow never
            # emitted. Stash it (do NOT die here — the dynamically-scoped
            # context teardown and completion build must still run) so the
            # outcome decision table can route it (task-fail by default,
            # workflow-fail when nondeterminism_as_workflow_fail is set).
            $self->_record_nondeterminism(
                "ResolveActivity for unknown seq $seq (no pending activity) — "
                . "non-determinism: the workflow never scheduled this activity");
            return;
        }

        my $resolution = $job->result;
        my $status     = defined $resolution ? $resolution->which_status : undef;
        $status //= '';

        # Local-activity backoff (spec section 21.2 — the one new mechanism).
        # Core resolves with `backoff` (DoBackoff) instead of retrying when the
        # next-attempt backoff exceeds local_retry_threshold. The outer future is
        # NOT resolved: the runner starts a real server timer for backoff_duration
        # and, when it fires, re-schedules the LA under a NEW seq with the
        # DoBackoff attempt and preserved original_schedule_time. Re-register the
        # state under the new seq (preserving the single outer future) so the body
        # stays unaware of the backoff. Only LAs ever carry `backoff`.
        if ($status eq 'backoff') {
            my $state = delete $local_activity_state{$seq};
            unless (defined $state) {
                # A backoff for a seq with no LA state: tolerate if it was a
                # cancelled LA (stale), else it is non-determinism. (We already
                # popped %pending_activities above; re-record nothing for a
                # known-cancelled seq.)
                return if delete $cancelled_activity_seqs{$seq};
                $self->_record_nondeterminism(
                    "ResolveActivity{backoff} for unknown seq $seq (no pending "
                    . "local activity) — non-determinism");
                return;
            }

            my $backoff   = $resolution->backoff;
            my $attempt   = $backoff->attempt;
            my $orig_time = $backoff->original_schedule_time;
            my $duration  = $backoff->backoff_duration;
            # Seconds for start_timer: Duration -> float.
            my $secs = ($duration ? $duration->seconds : 0)
                + ($duration && $duration->nanos ? $duration->nanos / 1e9 : 0);

            # Start a real (cancellable) server timer. On fire we re-schedule the
            # LA under a fresh seq. The outer future ($state->{future}) is carried
            # to the new seq untouched.
            my $timer = $self->start_timer($secs);
            my $timer_seq = $timer_seq_counter;   # the seq just allocated.
            $local_activity_backoff_timers{$timer_seq} = {
                state     => $state,
                attempt   => $attempt,
                orig_time => $orig_time,
            };

            $timer->on_done(sub {
                my $info = delete $local_activity_backoff_timers{$timer_seq}
                    or return;   # cancelled: do not re-schedule.
                my $st     = $info->{state};
                my $newseq = ++$activity_seq_counter;   # NEW seq, shared space.
                # Re-point the outer future's cancel hook at the new seq.
                $st->{future}->_rebind_seq($newseq);
                $local_activity_state{$newseq} = $st;
                $pending_activities{$newseq}   = $st->{future};
                $self->_emit_schedule_local_activity(
                    $newseq,
                    attempt                => $info->{attempt},
                    (defined $info->{orig_time}
                        ? (original_schedule_time => $info->{orig_time}) : ()),
                );
            });
            return;
        }

        # Terminal LA resolution (completed/failed/cancelled) drops the LA state.
        delete $local_activity_state{$seq};

        if ($status eq 'completed') {
            my $success = $resolution->completed;
            my $payload = defined $success ? $success->result : undef;
            my $value   = defined $payload
                ? $payload_converter->from_payload($payload)
                : undef;
            $future->done($value);
        }
        elsif ($status eq 'failed') {
            my $failure = $resolution->failed->failure;
            $future->fail(
                $failure_converter->from_failure($failure, $payload_converter));
        }
        elsif ($status eq 'cancelled') {
            my $failure = $resolution->cancelled->failure;
            $future->fail(
                $failure_converter->from_failure($failure, $payload_converter));
        }
        else {
            die "Temporalio::Workflow::Runner: ResolveActivity seq $seq had no "
              . "recognized status (got '$status')";
        }
        return;
    }

    # FireTimer { seq } — resolve the pending timer Future for this seq (spec
    # section 10.3; MUST-match sdk-python _apply_fire_timer). An absent handle
    # is ignored, not an error: the timer may have been cancelled (and removed)
    # earlier in this same activation, in which case FireTimer is stale. The
    # awaiting workflow continuation runs synchronously at resolve time
    # (Future::AsyncAwait on_ready), so progress is observed in the pump.
    method _apply_fire_timer ($job) {
        my $seq    = $job->seq;
        my $future = delete $pending_timers{$seq};
        return unless defined $future;   # cancelled/removed: ignore stale fire.
        $future->done unless $future->is_ready;
        return;
    }

    # ResolveChildWorkflowExecutionStart { seq, succeeded|failed|cancelled } —
    # the first stage of child resolution (spec section 18.2). `succeeded` sets
    # the run id and ->dones the start Future with the handle (the seq STAYS
    # mapped: the result job still comes). `failed`/`cancelled` are terminal for
    # the start AND the result — pop the seq and ->fail the start Future
    # (WorkflowAlreadyStarted on WORKFLOW_ALREADY_EXISTS, else a generic error;
    # Cancelled on `cancelled`). MUST-match sdk-python's start resolution.
    method _apply_resolve_child_workflow_start ($job) {
        my $seq    = $job->seq;
        my $handle = $pending_child_workflows{$seq};
        unless (defined $handle) {
            $self->_record_nondeterminism(
                "ResolveChildWorkflowExecutionStart for unknown seq $seq (no "
                . "pending child workflow) — non-determinism: the workflow never "
                . "started this child");
            return;
        }

        my $status = $job->which_status // '';
        if ($status eq 'succeeded') {
            # The child has started: record its run id and resolve the start
            # Future with the handle. Do NOT pop the seq — the result job for
            # this seq is still to come.
            $handle->_resolve_started($job->succeeded->run_id);
        }
        elsif ($status eq 'failed') {
            delete $pending_child_workflows{$seq};
            my $failed = $job->failed;
            # cause is the StartChildWorkflowExecutionFailedCause enum:
            # WORKFLOW_ALREADY_EXISTS = 1 -> WorkflowAlreadyStarted.
            my $exc = (($failed->cause // 0) == 1)
                ? Temporalio::Exception::WorkflowAlreadyStarted->new(
                      message       => 'Child workflow already started',
                      workflow_id   => $failed->workflow_id,
                      workflow_type => $failed->workflow_type,
                  )
                : Temporalio::Exception->new(
                      message => 'Child workflow failed to start (cause '
                          . ($failed->cause // 0) . ')',
                  );
            $handle->start_future->fail($exc)
                unless $handle->start_future->is_ready;
        }
        elsif ($status eq 'cancelled') {
            delete $pending_child_workflows{$seq};
            # core builds the ChildWorkflowFailure->CancelledFailure; map it.
            my $failure = $job->cancelled->failure;
            my $exc = defined $failure
                ? $failure_converter->from_failure($failure, $payload_converter)
                : Temporalio::Exception::Cancelled->new(
                      message => 'Child workflow cancelled before start');
            $handle->start_future->fail($exc)
                unless $handle->start_future->is_ready;
        }
        else {
            die "Temporalio::Workflow::Runner: "
              . "ResolveChildWorkflowExecutionStart seq $seq had no recognized "
              . "status (got '$status')";
        }
        return;
    }

    # ResolveChildWorkflowExecution { seq, result } — the second (terminal)
    # stage (spec section 18.2). Look up by seq (unknown -> non-determinism via
    # _record_nondeterminism), read the ChildWorkflowResult oneof: `completed`
    # -> ->done with the converted result; `failed`/`cancelled` -> ->fail with
    # Temporalio::Exception::ChildWorkflow whose cause is the mapped failure.
    # Pop the seq. MUST-match sdk-python's child result resolution.
    method _apply_resolve_child_workflow ($job) {
        my $seq    = $job->seq;
        my $handle = delete $pending_child_workflows{$seq};
        unless (defined $handle) {
            $self->_record_nondeterminism(
                "ResolveChildWorkflowExecution for unknown seq $seq (no pending "
                . "child workflow) — non-determinism: the workflow never started "
                . "this child");
            return;
        }

        my $future     = $handle->result_future;
        return if $future->is_ready;   # already cancelled via the handle.

        my $resolution = $job->result;
        my $status     = defined $resolution ? $resolution->which_status : '';
        $status //= '';

        if ($status eq 'completed') {
            my $success = $resolution->completed;
            my $payload = defined $success ? $success->result : undef;
            my $value   = defined $payload
                ? $payload_converter->from_payload($payload)
                : undef;
            $future->done($value);
        }
        elsif ($status eq 'failed' || $status eq 'cancelled') {
            # Wrap the mapped failure in a ChildWorkflow exception (spec section
            # 18.3): the underlying failure (an application error, a Cancelled,
            # ...) is the `cause`.
            my $inner   = $status eq 'failed'
                ? $resolution->failed->failure
                : $resolution->cancelled->failure;
            my $cause = defined $inner
                ? $failure_converter->from_failure($inner, $payload_converter)
                : undef;
            $future->fail(Temporalio::Exception::ChildWorkflow->new(
                message      => 'Child workflow execution failed',
                workflow_id  => $handle->id,
                (defined $cause ? (cause => $cause) : ()),
            ));
        }
        else {
            die "Temporalio::Workflow::Runner: ResolveChildWorkflowExecution "
              . "seq $seq had no recognized status (got '$status')";
        }
        return;
    }

    # ResolveSignalExternalWorkflow { seq, failure? } — settle a pending
    # child-targeted (spec section 18) or external-handle (spec section 20)
    # signal Future. No failure -> ->done; a populated failure -> ->fail with the
    # mapped exception (failure_converter->from_failure, surfacing a not-found as
    # Exception::Application — spec section 20.3). An unknown seq is tolerated
    # (the signal Future may have already been resolved); a seq whose Future was
    # cancelled in-flight (CancelSignalWorkflow emitted) is already ready, so the
    # is_ready guard drops the late resolve cleanly (spec section 20.2).
    method _apply_resolve_signal_external_workflow ($job) {
        my $seq    = $job->seq;
        my $future = delete $pending_external_signals{$seq};
        return unless defined $future;
        return if $future->is_ready;

        my $failure = $job->can('failure') ? $job->failure : undef;
        if (defined $failure) {
            $future->fail(
                $failure_converter->from_failure($failure, $payload_converter));
        }
        else {
            $future->done;
        }
        return;
    }

    # ResolveRequestCancelExternalWorkflow { seq, failure? } — settle a pending
    # external-handle cancel Future (spec section 20). No failure -> ->done; a
    # populated failure -> ->fail via failure_converter->from_failure (a
    # not-found surfaces as Exception::Application — spec section 20.3). An
    # unknown seq is tolerated. Cancel requests have no counter-cancel, so the
    # Future is never cancelled in-flight.
    method _apply_resolve_request_cancel_external_workflow ($job) {
        my $seq    = $job->seq;
        my $future = delete $pending_external_cancels{$seq};
        return unless defined $future;
        return if $future->is_ready;

        my $failure = $job->can('failure') ? $job->failure : undef;
        if (defined $failure) {
            $future->fail(
                $failure_converter->from_failure($failure, $payload_converter));
        }
        else {
            $future->done;
        }
        return;
    }

    # CancelWorkflow (spec section 10.3 / T-wf-12): mark the run cancel-requested
    # and cancel the run's pending Futures. Cancelling a pending activity/timer
    # Future fails it with Temporalio::Exception::Cancelled (the timer Future
    # already does this via its on_cancel override; pending activity Futures are
    # failed directly here), which raises Cancelled at the awaiting site. The
    # main run Future is cancelled too, in case the body parked on something
    # other than a tracked pending Future. If a Cancelled then propagates out of
    # :Run, the outcome decision table emits CancelWorkflowExecution (NOT a
    # FailWorkflowExecution). MUST-match sdk-python _apply_cancel_workflow:
    # set self._cancel_requested and cancel the workflow's primary task.
    method _apply_cancel_workflow ($job) {
        $cancel_requested = 1;

        # Propagate the cancellation down the tree (spec section 10.3 cancel
        # chain / T-act-9; MUST-match sdk-python _apply_cancel_workflow ->
        # primary task cancel -> the await in each child op raises CancelledError
        # and its handle emits the per-op cancel command). Cancel every pending
        # activity Future via its own cancel hook: that emits RequestCancelActivity
        # (so core forwards the cancel to the running activity — unless the
        # activity is ABANDON-typed, which never asks core to cancel) and then
        # fails the Future with Cancelled, so the awaiting body raises a proper
        # Temporal cancellation (a natively-cancelled Future would surface a bare
        # "was cancelled" string, losing the exception identity). Timer Futures
        # carry the analogous override (emit CancelTimer + fail Cancelled).
        # Continuations run synchronously at resolve time, so the body observes
        # the cancellation before _pump/_build_completion.
        # Backing-off local activities (spec section 21.2 / T-local-13) are NOT
        # in %pending_activities — their state is stashed on a backoff timer
        # while parked. Cancel each pending backoff timer (CancelTimer, dropping
        # its re-schedule) and fail the LA's outer future Cancelled. Do this
        # before the generic timer loop so the re-schedule on_done never fires.
        for my $tseq (keys %local_activity_backoff_timers) {
            my $info  = delete $local_activity_backoff_timers{$tseq};
            my $timer = $pending_timers{$tseq};
            $timer->cancel if defined $timer && !$timer->is_ready;
            my $la_future = $info->{state}{future};
            if (defined $la_future && !$la_future->is_ready) {
                $la_future->fail(Temporalio::Exception::Cancelled->new(
                    message => 'Local activity cancelled (workflow cancelled)',
                ));
            }
        }
        for my $seq (keys %pending_activities) {
            my $future = $pending_activities{$seq};
            next if !defined $future || $future->is_ready;
            # A local-activity future's whole-workflow cancel always raises (the
            # primary-task cancel does not honour wait_cancellation_completed),
            # so use _force_cancel rather than the wait-honouring ->cancel.
            if ($future->isa('Temporalio::Workflow::Runner::_LocalActivityFuture')) {
                $future->_force_cancel;
            }
            else {
                $future->cancel;
            }
        }
        for my $seq (keys %pending_timers) {
            my $future = $pending_timers{$seq};
            $future->cancel if defined $future && !$future->is_ready;
        }
        # Child workflows join the cancel chain (spec section 18.2 / T-child-11):
        # a whole-workflow CancelWorkflow cancels the primary task, so each
        # pending child handle is cancelled (emitting CancelChildWorkflowExecution
        # unless abandon) AND its pending start/result awaits are failed with
        # Cancelled so the awaiting body observes the cancellation in this
        # activation (mirrors T-act-9 for activities). Unlike an explicit
        # $handle->cancel — which honours the wait_* cancellation_type and may
        # stay parked — the primary-task cancel always raises at the await. The
        # handle's cancel de-registers the seq, so snapshot the keys first.
        for my $seq (keys %pending_child_workflows) {
            my $handle = $pending_child_workflows{$seq} // next;
            $handle->cancel;   # emit the cancel command (honours abandon).
            delete $pending_child_workflows{$seq};
            for my $f ($handle->start_future, $handle->result_future) {
                next if $f->is_ready;
                $f->fail(Temporalio::Exception::Cancelled->new(
                    message => 'Child workflow cancelled (workflow cancelled)',
                ));
            }
        }
        if (defined $main_run_future && !$main_run_future->is_ready) {
            $main_run_future->cancel;
        }
        return;
    }

    # UpdateRandomSeed { randomness_seed } — re-seed the deterministic RNG (spec
    # section 10.4; MUST-match sdk-python _apply_update_random_seed, which calls
    # self._random.seed(seed)). Math::Random::ISAAC::XS has no in-place reseed,
    # so replace the generator with a freshly-seeded one — equivalent for the
    # determinism contract (subsequent draws are seeded from the new value).
    method _apply_update_random_seed ($job) {
        $rng = _make_rng($job->randomness_seed // 0);
        return;
    }

    # NotifyHasPatch { patch_id } — record that the server reports this patch
    # present in history (spec section 10.3 "record in workflow info"; MUST-match
    # sdk-python _apply_notify_has_patch, which adds to self._patches_notified).
    # Sent pre-emptively, so during replay patched($id) returns true for a
    # notified id. The id is also surfaced in workflow info.
    method _apply_notify_has_patch ($job) {
        $patches_notified{ $job->patch_id } = 1;
        return;
    }

    # SignalWorkflow { signal_name, input } — route the signal to the matching
    # :Signal handler, the dynamic catch-all handler if no named match, or buffer
    # it (spec section 10.3; MUST-match sdk-python _apply_signal_workflow). The
    # handler is a METHOD on the instance, so a signal arriving before the
    # instance exists (e.g. ordered before InitializeWorkflow in the init
    # activation) is buffered and drained right after _apply_initialize creates
    # the instance. A signal whose name has no named handler and no dynamic
    # handler is buffered too (T-wf-3 QUEUEING), held in arrival order until a
    # matching handler appears (or indefinitely in this static model — it never
    # fails the workflow).
    method _apply_signal_workflow ($job) {
        my $name = $job->signal_name // '';

        # No instance yet: the handler can only run against the instance the
        # InitializeWorkflow job creates. Buffer for the post-init drain.
        if (!defined $instance) {
            push $buffered_signals{$name}->@*, $job;
            return;
        }

        my ($handler, $is_dynamic) = $self->_resolve_signal_handler($name);
        if (!defined $handler) {
            # No named or dynamic handler: buffer (a dynamic handler may be
            # registered later; sdk-python keeps these for a later-added handler).
            push $buffered_signals{$name}->@*, $job;
            return;
        }

        $self->_dispatch_signal($handler, $is_dynamic, $job);
        return;
    }

    # Resolve a signal handler by name (spec section 10.3): the named :Signal
    # handler if one matches, else the dynamic catch-all if registered. Returns
    # ($methodref, $is_dynamic) or (undef) when neither exists. MUST-match
    # sdk-python's `self._signals.get(name) or self._signals.get(None)`.
    method _resolve_signal_handler ($name) {
        my $defs = $workflow_class->_workflow_defs;
        if (my $named = $defs->{signals}{$name}) {
            return ($named, 0);
        }
        if (my $dynamic = $defs->{dynamic}{signal}) {
            return ($dynamic, 1);
        }
        return (undef);
    }

    # Invoke a resolved signal handler (spec section 10.3 ASYNC HANDLER
    # TRACKING). Named handlers are called with the decoded args; a dynamic
    # handler is called with ($name, @args) (mirrors sdk-python's dynamic signal
    # (name, args)). The handler may be sync OR async, so run it through
    # Future->call(sub { Future->wrap(...) }) — Future->wrap passes a returned
    # Future through and normalises a plain return into a done Future, while
    # Future->call routes a synchronous die into a failed Future. The resulting
    # Future is tracked in the in-progress-handlers set until it is ready, so the
    # workflow is not considered complete while the handler is still running.
    method _dispatch_signal ($handler, $is_dynamic, $job) {
        my @args = map { $payload_converter->from_payload($_) }
            (($job->input // [])->@*);
        my $name = $job->signal_name // '';

        my $future = Future->call(sub {
            return Future->wrap(
                $is_dynamic
                    ? $instance->$handler($name, @args)
                    : $instance->$handler(@args)
            );
        });

        # An already-ready handler (a synchronous handler that returned or threw)
        # needs no tracking. A pending (async) handler is tracked and removed
        # from the in-progress set when it becomes ready.
        if (!$future->is_ready) {
            my $id = ++$handler_seq;
            $in_progress_handlers{$id} = $future;
            $future->on_ready(sub { delete $in_progress_handlers{$id} });
        }
        return;
    }

    # Drain the buffered-signal queue (spec section 10.3 T-wf-3 QUEUEING;
    # MUST-match sdk-python draining _buffered_signals when a handler appears).
    # Called after _apply_initialize creates the instance. Signals whose name now
    # resolves to a handler (named or dynamic) are dispatched in arrival order
    # and removed from the buffer; a signal with still no handler stays buffered.
    method _drain_buffered_signals {
        return unless defined $instance;
        for my $name (keys %buffered_signals) {
            my ($handler, $is_dynamic) = $self->_resolve_signal_handler($name);
            next unless defined $handler;   # still no handler: keep buffered.
            my $jobs = delete $buffered_signals{$name};
            for my $job (@$jobs) {
                $self->_dispatch_signal($handler, $is_dynamic, $job);
            }
        }
        return;
    }

    # The names of signals still buffered (spec section 10.3 QUEUEING). Test
    # introspection helper — sorted for a stable view.
    method _buffered_signal_names { return [ sort keys %buffered_signals ] }

    # DoUpdate { id, protocol_instance_id, name, input, run_validator } — run an
    # update handler (spec section 19.2; MUST-match sdk-python _apply_do_update).
    # An update is a TWO-PHASE job: a synchronous read-only validation phase then
    # an asynchronous tracked execution phase.
    #
    #   1. No instance yet (the handler is a METHOD): buffer for the post-init
    #      drain (mirrors a pre-instance signal, but updates never buffer for a
    #      missing handler — only for a missing instance).
    #   2. Lookup defs->{updates}{name} then defs->{dynamic}{update}. No handler
    #      on a live instance -> immediate UpdateResponse.rejected (no buffering).
    #   3. Validation (sync, read-only): only when run_validator AND a validator
    #      is registered. Run it under the read-only guard. A throw -> a single
    #      UpdateResponse.rejected (converted failure), no acceptance. A read-only
    #      violation (the validator issued a command) -> a workflow TASK failure.
    #   4. Acceptance: emit UpdateResponse.accepted, then invoke the handler via
    #      Future->call (sync or async). A returned value -> UpdateResponse.completed
    #      with the encoded result. A Temporal-failure-type throw -> a post-accept
    #      UpdateResponse.rejected. Any other die -> a workflow TASK failure.
    #      An async handler's Future is tracked in %in_progress_handlers.
    method _apply_do_update ($job) {
        my $name                 = $job->name // '';
        my $protocol_instance_id = $job->protocol_instance_id // '';

        # No instance yet: buffer for the post-init drain.
        if (!defined $instance) {
            push @buffered_updates, $job;
            return;
        }

        my ($handler, $is_dynamic) = $self->_resolve_update_handler($name);
        if (!defined $handler) {
            # Unknown name, no dynamic handler -> immediate rejection (NOT
            # buffered indefinitely, unlike signals — spec section 19.2 step 2).
            my $known = join ' ',
                sort keys $workflow_class->_workflow_defs->{updates}->%*;
            my $err = Temporalio::Exception->new(
                message => "Update handler for '$name' expected but not found, "
                         . "and there is no dynamic handler. known updates: "
                         . "[$known]",
            );
            push @commands, Temporalio::Workflow::Commands::update_response(
                $protocol_instance_id,
                rejected => $failure_converter->to_failure($err, $payload_converter),
            );
            return;
        }

        my @args = map { $payload_converter->from_payload($_) }
            (($job->input // [])->@*);

        # --- validation phase (sync, read-only) ------------------------------
        # A named handler with a registered validator is validated only when the
        # job asks (run_validator is false on replay). A dynamic handler is never
        # validated (there is no dynamic validator).
        if ($job->run_validator && !$is_dynamic) {
            my $validator = $workflow_class->_workflow_defs->{validators}{$name};
            if (defined $validator) {
                my $result = $self->_run_update_validator($validator, \@args);
                # A read-only-context violation is a workflow TASK failure: the
                # error is stashed and the outcome table routes it (no
                # UpdateResponse emitted).
                return if $result->{task_failure};
                # A validator throw is an update REJECTION (single rejected,
                # no acceptance).
                if (defined $result->{rejected}) {
                    push @commands,
                        Temporalio::Workflow::Commands::update_response(
                            $protocol_instance_id,
                            rejected => $result->{rejected},
                        );
                    return;
                }
            }
        }

        # --- acceptance + execution phase (async, tracked) -------------------
        push @commands, Temporalio::Workflow::Commands::update_response(
            $protocol_instance_id, accepted => 1);

        my $future = Future->call(sub {
            return Future->wrap(
                $is_dynamic
                    ? $instance->$handler($name, @args)
                    : $instance->$handler(@args)
            );
        });

        # When the handler Future is ready now (a synchronous handler), settle
        # the update in this activation. Otherwise track it and settle when it
        # becomes ready (a later activation re-pumps and the on_ready fires).
        my $settle = sub {
            $self->_settle_update($protocol_instance_id, $future);
        };
        if ($future->is_ready) {
            $settle->();
        }
        else {
            my $id = ++$handler_seq;
            $in_progress_handlers{$id} = $future;
            $future->on_ready(sub {
                delete $in_progress_handlers{$id};
                $settle->();
            });
        }
        return;
    }

    # Resolve an update handler by name (spec section 19.2): the named :Update
    # handler if one matches, else the dynamic catch-all if registered. Returns
    # ($methodref, $is_dynamic) or (undef). MUST-match sdk-python
    # `self._updates.get(name) or self._updates.get(None)`.
    method _resolve_update_handler ($name) {
        my $defs = $workflow_class->_workflow_defs;
        if (my $named = $defs->{updates}{$name}) {
            return ($named, 0);
        }
        if (my $dynamic = $defs->{dynamic}{update}) {
            return ($dynamic, 1);
        }
        return (undef);
    }

    # Run a sync update validator under the read-only guard (spec section 19.2
    # step 3). Returns a hashref:
    #   { rejected => $failure_proto }  — the validator threw a normal failure
    #   { task_failure => 1 }           — the validator violated read-only
    #   {}                              — the validator passed (accept)
    # A read-only violation (the validator issued a command) is routed as a
    # workflow TASK failure via $current_activation_error.
    method _run_update_validator ($validator, $args) {
        my $future = Future->call(sub {
            dynamically $read_only_depth = $read_only_depth + 1;
            return Future->wrap($instance->$validator(@$args));
        });
        if (my @failure = $future->failure) {
            my $err = $failure[0];
            # A read-only-context violation is a task failure, NOT a rejection.
            if (Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception')
                && ($err->message // '') =~ /read-only context/)
            {
                $current_activation_error //= $err;
                return { task_failure => 1 };
            }
            return {
                rejected =>
                    $failure_converter->to_failure($err, $payload_converter),
            };
        }
        return {};
    }

    # Settle an accepted update once its handler Future is ready (spec section
    # 19.2 step 4): a returned value -> UpdateResponse.completed; a Temporal
    # failure-type throw -> UpdateResponse.rejected (post-accept); any other die
    # -> a workflow TASK failure.
    method _settle_update ($protocol_instance_id, $future) {
        if (my @failure = $future->failure) {
            my $err = $failure[0];
            if ($self->_is_workflow_failure_exception($err)) {
                push @commands, Temporalio::Workflow::Commands::update_response(
                    $protocol_instance_id,
                    rejected =>
                        $failure_converter->to_failure($err, $payload_converter),
                );
            }
            else {
                # A plain die post-acceptance is a workflow TASK failure.
                $current_activation_error //= $err;
            }
            return;
        }
        my $result  = ($future->result)[0];
        my $payload = $payload_converter->to_payload($result);
        push @commands, Temporalio::Workflow::Commands::update_response(
            $protocol_instance_id,
            completed => $payload,
        );
        return;
    }

    # Drain the buffered-update queue (spec section 19.2): updates buffered
    # before the instance existed are re-applied in arrival order after
    # _apply_initialize creates the instance (mirrors _drain_buffered_signals).
    method _drain_buffered_updates {
        return unless defined $instance;
        my @jobs = @buffered_updates;
        @buffered_updates = ();
        $self->_apply_do_update($_) for @jobs;
        return;
    }

    # QueryWorkflow { query_id, query_type, arguments } — run the matching
    # :Query handler and emit a RespondToQuery command (spec section 10.3;
    # MUST-match sdk-python _apply_query_workflow). Queries are SYNCHRONOUS in
    # effect and MUST NOT mutate workflow state or produce other commands: they
    # are ordered LAST in the activation (set 3 of _ordered_job_sets) so they
    # observe the most up-to-date state, and they run against the live instance.
    # A handler that throws does NOT fail the workflow or the task — it produces
    # a RespondToQuery carrying the converted failure (the dying-handler case).
    # A query with no named handler and no dynamic handler is itself a query
    # failure (sdk-python raises "Query handler ... not found").
    method _apply_query_workflow ($job) {
        my $query_id = $job->query_id // '';
        my $name     = $job->query_type // '';

        my ($handler, $is_dynamic) = $self->_resolve_query_handler($name);
        if (!defined $handler) {
            my $known = join ' ', sort keys $workflow_class->_workflow_defs->{queries}->%*;
            my $err = Temporalio::Exception->new(
                message => "Query handler for '$name' expected but not found, "
                         . "known queries: [$known]",
            );
            push @commands, Temporalio::Workflow::Commands::respond_to_query(
                $query_id,
                failure => $failure_converter->to_failure($err, $payload_converter),
            );
            return;
        }

        # Decode the query arguments. A dynamic handler is called with
        # ($name, @args) (mirrors sdk-python's dynamic query (name, args)); a
        # named one gets the bare decoded args. The handler is run through
        # Future->call(sub { Future->wrap(...) }) — the lessons.md idiom for
        # sync-or-async user code: it routes a synchronous die into a failed
        # Future and normalises a plain return into a done Future. A query is
        # synchronous in effect, so the Future is expected to be already ready;
        # we read its outcome immediately.
        my @args = map { $payload_converter->from_payload($_) }
            (($job->arguments // [])->@*);

        my $future = Future->call(sub {
            return Future->wrap(
                $is_dynamic
                    ? $instance->$handler($name, @args)
                    : $instance->$handler(@args)
            );
        });

        if (my @failure = $future->failure) {
            # Dying handler -> query FAILED response (not a workflow/task fail).
            push @commands, Temporalio::Workflow::Commands::respond_to_query(
                $query_id,
                failure => $failure_converter->to_failure($failure[0], $payload_converter),
            );
            return;
        }

        my $result = ($future->result)[0];
        my $payload = defined $result
            ? $payload_converter->to_payload($result)
            : undef;
        push @commands, Temporalio::Workflow::Commands::respond_to_query(
            $query_id,
            response => $payload,
        );
        return;
    }

    # Resolve a query handler by name (spec section 10.3): the named :Query
    # handler if one matches, else the dynamic catch-all if registered. Returns
    # ($methodref, $is_dynamic) or (undef) when neither exists. MUST-match
    # sdk-python's `self._queries.get(name) or self._queries.get(None)`.
    method _resolve_query_handler ($name) {
        my $defs = $workflow_class->_workflow_defs;
        if (my $named = $defs->{queries}{$name}) {
            return ($named, 0);
        }
        if (my $dynamic = $defs->{dynamic}{query}) {
            return ($dynamic, 1);
        }
        return (undef);
    }

    # True when no signal/update handler is still in-flight (spec section 10.3 /
    # 19.2 ASYNC HANDLER TRACKING; MUST-match sdk-python
    # workflow_all_handlers_finished). Public surface via
    # Temporalio::Workflow::all_handlers_finished: authors wait_condition on it
    # to gate completion explicitly. The runner WARNS (it no longer hard-blocks)
    # when :Run returns with a handler still in-flight (warn-and-complete).
    method _all_handlers_finished { return %in_progress_handlers ? 0 : 1 }

    # Assert the runner is NOT inside a read-only block (spec section 19.2): an
    # update validator must not issue commands or mutate workflow state. Called
    # at the head of every command-emitting runner method; inside a validator it
    # throws a ReadOnlyContext error that _apply_do_update routes to a workflow
    # TASK failure (NOT an update rejection). MUST-match sdk-python
    # _as_read_only / ReadOnlyContextError.
    method _assert_writable ($what) {
        return if $read_only_depth <= 0;
        die Temporalio::Exception->new(
            message => "Temporalio::Workflow::Runner: $what is not allowed in a "
                     . "read-only context (update validator must not mutate "
                     . "state or issue commands)",
        );
    }

    # Stash a non-determinism error (spec section 10.3 / T-wf-13) for the outcome
    # decision table. Built as a Temporalio::Exception::Nondeterminism so the
    # decision table can recognize it and route it by the
    # nondeterminism_as_workflow_fail flag. Only the first such error is kept.
    method _record_nondeterminism ($message) {
        $nondeterminism_error //= Temporalio::Exception::Nondeterminism->new(
            message => "Temporalio::Workflow::Runner: $message",
        );
        return;
    }

    # Pump phase (spec section 10.3 pump semantics): drive any ready Future
    # continuations. For the skeleton there are no pending workflow Futures, so
    # the main run Future is either already ready (Future::AsyncAwait ran the
    # body to completion synchronously) or genuinely blocked on a future a
    # later phase resolves. No IO::Async, no wall-clock.
    method _pump (%opts) {
        # Future::AsyncAwait runs the body and fires its on_ready continuations
        # synchronously when the awaited futures resolve, so activity/timer
        # resolution drives the body without any explicit loop here. The one
        # thing the pump must drive is the wait_condition re-check: after a job
        # set is applied (a signal mutated state, a timer/activity resolved), any
        # pending predicate that is now true resolves its future and resumes the
        # awaiting continuation in this same activation (spec section 10.2 /
        # T-wf-5; MUST-match sdk-python _run_once's check_conditions pass).
        #
        # check_conditions is gated by the caller: it is FALSE for the patch and
        # query job sets (a query activation must not advance the workflow body),
        # TRUE for the signal and non-query sets. Defaults to TRUE so callers
        # that pump outside the job-set loop keep the prior re-check behavior.
        my $check = exists $opts{check_conditions} ? $opts{check_conditions} : 1;
        $self->_check_conditions if $check;
        return;
    }

    # Build the WorkflowActivationCompletion from the run outcome + command
    # buffer. This is the spec section 10.3 step 6 OUTCOME DECISION TABLE
    # (MUST-match sdk-python _run_top_level_workflow_function /
    # _set_workflow_failure):
    #
    #   - A non-determinism error detected this activation -> task-fail by
    #     default, FailWorkflowExecution when nondeterminism_as_workflow_fail
    #     (checked first: it concerns the activation, not the run body) (T-wf-13).
    #   - continue_as_new control signal escaped :Run ->
    #     ContinueAsNewWorkflowExecution (caught BEFORE the failure branch so it
    #     is never mistaken for an error) (T-wf-8).
    #   - A Cancelled escaped after a CancelWorkflow job ->
    #     CancelWorkflowExecution (NOT a failure) (T-wf-12).
    #   - A Temporal failure exception (Temporalio::Exception::*) OR a class
    #     listed in workflow_failure_exception_types -> FailWorkflowExecution
    #     (T-wf-15b/c).
    #   - Any other exception (plain die, foreign class) -> the whole completion
    #     is `failed`: a workflow TASK failure the server retries (T-wf-15a).
    #   - The run method returned a value -> CompleteWorkflowExecution { result }
    #     (T-wf-11); a still-blocked body emits its buffered commands only.
    method _build_completion {
        # 1. Non-determinism takes precedence (it is an activation-level fault,
        #    detected while applying jobs, before the run body even ran).
        if (defined $nondeterminism_error) {
            return $nondeterminism_as_workflow_fail
                ? $self->_workflow_failed_completion($nondeterminism_error)
                : $self->_task_failed_completion($nondeterminism_error);
        }

        # 1b. An activation-level error recorded while applying a job (spec
        #     section 19.2): a validator that violated the read-only contract, or
        #     a plain die in an update handler. Routed as a workflow TASK failure
        #     (the server retries the task), like a non-determinism error.
        if (defined $current_activation_error) {
            return $self->_task_failed_completion($current_activation_error);
        }

        if (defined $main_run_future && $main_run_future->is_ready) {
            if (my @failure = $main_run_future->failure) {
                return $self->_outcome_for_failure($failure[0]);
            }
            # WARN-AND-COMPLETE (spec section 19.2, corrected v0.2.1): when :Run
            # returns with a signal/update handler still in-flight, WARN and
            # complete the workflow anyway, abandoning the handler — parity with
            # sdk-python (_warn_if_unfinished_handlers) and sdk-ruby. This is NOT
            # a hard block: authors who want to wait use
            # wait_condition(\&Temporalio::Workflow::all_handlers_finished).
            unless ($self->_all_handlers_finished) {
                warn "Temporalio::Workflow::Runner: workflow completed with "
                   . "unfinished in-flight handler(s); their work is abandoned. "
                   . "Use wait_condition on all_handlers_finished to wait for "
                   . "them before returning from :Run.\n";
            }
            # Success: the run method returned a value.
            my $result = ($main_run_future->result)[0];
            my $payload = defined $result
                ? $payload_converter->to_payload($result)
                : undef;
            push @commands,
                Temporalio::Workflow::Commands::complete_workflow_execution($payload);
        }

        return $self->_successful_completion;
    }

    # Route a value that escaped :Run through the failure decision table.
    method _outcome_for_failure ($err) {
        # continue_as_new: a control signal, NOT a failure — caught first so it
        # is never converted as an error (mirrors sdk-python catching
        # _ContinueAsNewError before the generic Exception branch).
        if (Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Workflow::ContinueAsNew'))
        {
            push @commands, $self->_build_continue_as_new_command($err);
            return $self->_successful_completion;
        }

        # Cancelled after a CancelWorkflow job -> CancelWorkflowExecution (NOT a
        # FailWorkflowExecution). Gated on cancel_requested: a Cancelled with no
        # cancel request is a normal failure (sdk-python self._cancel_requested).
        if ($cancel_requested
            && Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Cancelled'))
        {
            push @commands,
                Temporalio::Workflow::Commands::cancel_workflow_execution();
            return $self->_successful_completion;
        }

        # A Temporal failure exception, or a class listed in
        # workflow_failure_exception_types, fails the WORKFLOW.
        if ($self->_is_workflow_failure_exception($err)) {
            return $self->_workflow_failed_completion($err);
        }

        # Anything else (plain die, foreign object not listed) fails the TASK.
        return $self->_task_failed_completion($err);
    }

    # workflow_is_failure_exception (MUST-match sdk-python): an escaped value
    # fails the WORKFLOW (rather than the task) if it is a Temporal failure
    # exception (any Temporalio::Exception::*) or an instance of any class in the
    # worker's workflow_failure_exception_types.
    method _is_workflow_failure_exception ($err) {
        return 0 unless Scalar::Util::blessed($err);
        return 1 if $err->isa('Temporalio::Exception');
        for my $type ($workflow_failure_exception_types->@*) {
            return 1 if $err->isa($type);
        }
        return 0;
    }

    # Build a ContinueAsNewWorkflowExecution command from the captured signal's
    # options (spec section 10.3 step 6 / T-wf-8; MUST-match sdk-python
    # _ContinueAsNewError._apply_command). Only the fields the caller set are
    # populated — continue-as-new does NOT re-use the old run's arguments.
    method _build_continue_as_new_command ($signal) {
        my %opts = $signal->options;
        my %fields;

        $fields{workflow_type} = $opts{workflow} if defined $opts{workflow};
        $fields{task_queue}    = $opts{task_queue} if defined $opts{task_queue};

        if (my $args = $opts{args}) {
            if (@$args) {
                $fields{arguments} =
                    [ map { $payload_converter->to_payload($_) } @$args ];
            }
        }

        for my $pair (
            [ run_timeout  => 'workflow_run_timeout' ],
            [ task_timeout => 'workflow_task_timeout' ],
        ) {
            my ($opt, $field) = @$pair;
            next unless defined $opts{$opt};
            $fields{$field} = _duration($opts{$opt});
        }

        if (defined(my $rp = $opts{retry_policy})) {
            $fields{retry_policy} = $rp->to_proto;
        }

        if (my $memo = $opts{memo}) {
            if (%$memo) {
                $fields{memo} = {
                    map { $_ => $payload_converter->to_payload($memo->{$_}) }
                        keys %$memo
                };
            }
        }

        if (my $headers = $opts{headers}) {
            if (%$headers) {
                $fields{headers} = {
                    map { $_ => $payload_converter->to_payload($headers->{$_}) }
                        keys %$headers
                };
            }
        }

        return Temporalio::Workflow::Commands::continue_as_new_workflow_execution(
            \%fields);
    }

    # A successful completion: the buffered commands (CompleteWorkflowExecution,
    # FailWorkflowExecution, CancelWorkflowExecution, ContinueAsNew..., or the
    # mid-run command set) wrapped in a Success status.
    method _successful_completion {
        my @out = @commands;

        # LEGACY QUERY (spec section 10.3; MUST-match sdk-core's completion
        # validator): a query with query_id "legacy_query" is delivered on its
        # own workflow task; core replays history to rebuild state, then the lang
        # SDK answers ONLY the query. If the completion carries the legacy-query
        # response alongside ANY other command (e.g. a CompleteWorkflow that the
        # replayed body produced when a buffered signal unblocked it), core
        # rejects it: "Workflow completion had a legacy query response along with
        # other commands." So when a legacy-query response is present, suppress
        # every non-query-response command — the workflow's commands were already
        # in history; only the query answer is new.
        if (_has_legacy_query_response(\@out)) {
            @out = grep { _is_query_response($_) } @out;
        }

        my $completion_class = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_completion.WorkflowActivationCompletion');
        return $completion_class->new({
            run_id     => $run_id,
            successful => { commands => \@out },
        });
    }

    # True when $cmd is a RespondToQuery command (its variant is the query
    # response oneof). The respond_to_query sub-message is a plain hashref
    # (proto sub-messages are not always blessed — lessons.md), so read it as a
    # hash, not via accessors.
    sub _is_query_response ($cmd) {
        return ($cmd->which_variant // '') eq 'respond_to_query';
    }

    # True when the command list contains a RespondToQuery whose query_id is the
    # sentinel "legacy_query" (sdk-core LEGACY_QUERY_ID).
    sub _has_legacy_query_response ($cmds) {
        for my $cmd (@$cmds) {
            next unless _is_query_response($cmd);
            my $rtq = $cmd->respond_to_query;
            return 1
                if ref $rtq eq 'HASH'
                && defined $rtq->{query_id}
                && $rtq->{query_id} eq 'legacy_query';
        }
        return 0;
    }

    # A workflow-FAILURE completion: a successful completion whose sole command
    # is FailWorkflowExecution carrying the converted failure (T-wf-15b/c). The
    # workflow execution itself fails (vs the task). Any commands already
    # buffered this activation are discarded — a failing run does not also emit
    # its earlier partial commands (sdk-python adds only the fail command).
    method _workflow_failed_completion ($err) {
        my $failure = $failure_converter->to_failure($err, $payload_converter);
        @commands = (
            Temporalio::Workflow::Commands::fail_workflow_execution($failure),
        );
        return $self->_successful_completion;
    }

    # A task-FAILURE completion: the entire WorkflowActivationCompletion is
    # `failed` (a workflow-TASK failure the server retries), carrying the
    # converted failure (T-wf-15a; sdk-python _current_activation_error path).
    # NO commands are emitted — the workflow execution is neither completed nor
    # failed.
    method _task_failed_completion ($err) {
        my $failure = $failure_converter->to_failure($err, $payload_converter);
        my $completion_class = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_completion.WorkflowActivationCompletion');
        return $completion_class->new({
            run_id => $run_id,
            failed => { failure => $failure },
        });
    }

    # The spec-mandated deterministic PRNG (spec section 10.4): a
    # Math::Random::ISAAC::XS instance seeded from the activation's
    # randomness_seed. The contract (T-wf-10): same seed -> same sequence,
    # different seed -> different sequence, no OS entropy. ISAAC exposes irand
    # (32-bit unsigned) and rand (float in [0,1)). File-scope sub inside the
    # class block so it is callable from methods.
    sub _make_rng ($seed) {
        return Math::Random::ISAAC::XS->new(int($seed // 0));
    }

    # Activity cancellation_type: spec string -> ActivityCancellationType enum
    # number. Defaults to try_cancel (0). The enum lives in
    # coresdk.workflow_commands: TRY_CANCEL=0, WAIT_CANCELLATION_COMPLETED=1,
    # ABANDON=2 (verified against the vendored workflow_commands.proto).
    my %CANCELLATION_TYPE = (
        try_cancel                   => 0,
        wait_cancellation_completed  => 1,
        abandon                      => 2,
    );
    sub _cancellation_type_number ($name) {
        return 0 unless defined $name;
        return $CANCELLATION_TYPE{$name}
            // die "Temporalio::Workflow::Runner: unknown cancellation_type "
                 . "'$name'";
    }

    # Child workflow cancellation_type: spec string -> ChildWorkflowCancellationType
    # enum number (verified against child_workflow.proto): abandon=0, try_cancel=1,
    # wait_cancellation_completed=2, wait_cancellation_requested=3. DEFAULT is
    # wait_cancellation_completed (2) per spec section 18.1 — NOT the proto zero
    # (abandon), NOT activities' try_cancel. A bad string dies at scheduling time.
    my %CHILD_CANCELLATION_TYPE = (
        abandon                      => 0,
        try_cancel                   => 1,
        wait_cancellation_completed  => 2,
        wait_cancellation_requested  => 3,
    );
    sub _child_cancellation_type_number ($name) {
        return 2 unless defined $name;   # default: wait_cancellation_completed.
        return $CHILD_CANCELLATION_TYPE{$name}
            // die "Temporalio::Workflow::Runner: unknown child workflow "
                 . "cancellation_type '$name'";
    }

    # parent_close_policy: spec string -> ParentClosePolicy enum number (verified
    # against child_workflow.proto): unspecified=0, terminate=1, abandon=2,
    # request_cancel=3. DEFAULT is terminate (1) per spec section 18.1.
    my %PARENT_CLOSE_POLICY = (
        unspecified    => 0,
        terminate      => 1,
        abandon        => 2,
        request_cancel => 3,
    );
    sub _parent_close_policy_number ($name) {
        return 1 unless defined $name;   # default: terminate.
        return $PARENT_CLOSE_POLICY{$name}
            // die "Temporalio::Workflow::Runner: unknown parent_close_policy "
                 . "'$name'";
    }

    # id_reuse_policy: spec string -> WorkflowIdReusePolicy enum number (verified
    # against temporal/api/enums/v1/workflow.proto): unspecified=0,
    # allow_duplicate=1, allow_duplicate_failed_only=2, reject_duplicate=3,
    # terminate_if_running=4. DEFAULT is allow_duplicate (1) per spec section 18.1.
    my %ID_REUSE_POLICY = (
        unspecified                  => 0,
        allow_duplicate              => 1,
        allow_duplicate_failed_only  => 2,
        reject_duplicate             => 3,
        terminate_if_running         => 4,
    );
    sub _id_reuse_policy_number ($name) {
        return 1 unless defined $name;   # default: allow_duplicate.
        return $ID_REUSE_POLICY{$name}
            // die "Temporalio::Workflow::Runner: unknown id_reuse_policy "
                 . "'$name'";
    }

    # Seconds (float) -> google.protobuf.Duration { seconds, nanos }. Mirrors
    # Temporalio::Common::RetryPolicy::_duration; the activity timeouts cross
    # the wire as Durations.
    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve(
            'google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
    }
}

# A Workflow::Future for timers whose ->cancel maps to a Temporalio::Exception::
# Cancelled FAILURE (not Future's native cancelled state). Kept in its own
# package because a `feature 'class'` file may declare only one `class :isa`
# once Future::AsyncAwait is loaded (lessons.md), and this is a plain Future
# subclass with one overridden method anyway. The override is the whole point:
# a natively-cancelled CPAN Future makes `await` throw a bare "was cancelled"
# string, losing the Temporal exception identity, whereas the reference SDKs
# raise a cancellation EXCEPTION into the awaiting frame.
package Temporalio::Workflow::Runner::_TimerFuture {
    use v5.38;
    use warnings;

    use parent -norequire, 'Temporalio::Workflow::Future';
    use Temporalio::Exception::Cancelled ();

    # _new_timer(seq => $seq, on_cancel => $cb) -> a pending timer future. The
    # on_cancel callback (emits CancelTimer + de-registers the pending timer)
    # runs exactly once, on the first ->cancel of a still-pending timer.
    sub _new_timer ($class, %args) {
        my $self = $class->new;
        $self->{_timer_on_cancel} = $args{on_cancel};
        return $self;
    }

    # cancel: emit the CancelTimer command (via the stored callback) and fail
    # the future with Temporalio::Exception::Cancelled so the await site sees a
    # proper Temporal cancellation. A no-op once the future is ready (already
    # fired or already cancelled), mirroring the references' pending-state guard.
    sub cancel ($self) {
        return $self if $self->is_ready;
        if (my $cb = delete $self->{_timer_on_cancel}) {
            $cb->();
        }
        $self->fail(Temporalio::Exception::Cancelled->new(
            message => 'Timer cancelled',
        ));
        return $self;
    }
}

# A Workflow::Future for activities whose ->cancel maps to a Temporalio::
# Exception::Cancelled FAILURE (not Future's native cancelled state), mirroring
# _TimerFuture. The on_cancel callback (supplied by schedule_activity) emits
# RequestCancelActivity (unless the activity is ABANDON-typed), records the seq
# as cancelled so a later stale ResolveActivity{cancelled} is tolerated, and
# de-registers the pending entry. The cancel then fails the Future with
# Cancelled so the awaiting body raises a proper Temporal cancellation
# (a natively-cancelled CPAN Future would surface a bare "was cancelled" string,
# losing the exception identity — same reasoning as the timer override). This
# is the activity end of the spec section 10.3 cancel chain (T-act-9).
package Temporalio::Workflow::Runner::_ActivityFuture {
    use v5.38;
    use warnings;

    use parent -norequire, 'Temporalio::Workflow::Future';
    use Temporalio::Exception::Cancelled ();

    # _new_activity(seq => $seq, on_cancel => $cb) -> a pending activity future.
    # The on_cancel callback runs exactly once, on the first ->cancel of a
    # still-pending activity.
    sub _new_activity ($class, %args) {
        my $self = $class->new;
        $self->{_activity_on_cancel} = $args{on_cancel};
        return $self;
    }

    # cancel: run the stored callback (emit RequestCancelActivity unless abandon,
    # record the cancelled seq, de-register) then fail the future with Cancelled.
    # A no-op once the future is ready (already resolved or already cancelled).
    sub cancel ($self) {
        return $self if $self->is_ready;
        if (my $cb = delete $self->{_activity_on_cancel}) {
            $cb->();
        }
        $self->fail(Temporalio::Exception::Cancelled->new(
            message => 'Activity cancelled',
        ));
        return $self;
    }
}

# A Workflow::Future for LOCAL activities (spec section 21). Like _ActivityFuture
# it raises a Temporalio::Exception::Cancelled on ->cancel rather than entering
# Future's native cancelled state, but the cancel BEHAVIOUR is delegated to the
# runner (Runner::_on_local_activity_cancel) so it can honour the cancellation
# type: try_cancel/abandon resolve now, wait_cancellation_completed parks until
# the cancelled resolve, and a backing-off LA cancels its server timer. The
# future carries its CURRENT seq (re-bound on a backoff re-schedule) and the
# is_abandon/wait flags captured at schedule time.
package Temporalio::Workflow::Runner::_LocalActivityFuture {
    use v5.38;
    use warnings;

    use parent -norequire, 'Temporalio::Workflow::Future';
    use Scalar::Util ();
    use Temporalio::Exception::Cancelled ();

    # _new_local(seq, runner, is_abandon, wait) -> a pending LA future.
    sub _new_local ($class, %args) {
        my $self = $class->new;
        $self->{_la_seq}        = $args{seq};
        $self->{_la_runner}     = $args{runner};
        Scalar::Util::weaken($self->{_la_runner});
        $self->{_la_is_abandon} = $args{is_abandon} ? 1 : 0;
        $self->{_la_wait}       = $args{wait} ? 1 : 0;
        return $self;
    }

    # _rebind_seq($newseq) — a backoff re-schedule moved this LA to a new seq;
    # update the seq the cancel hook will target.
    sub _rebind_seq ($self, $newseq) {
        $self->{_la_seq} = $newseq;
        return $self;
    }

    # cancel: explicit handle cancellation (spec section 21.2). Delegate to the
    # runner, which emits the appropriate command and returns whether to resolve
    # Cancelled now (try_cancel/abandon/backing-off) or PARK (wait). A no-op once
    # the future is ready.
    sub cancel ($self) {
        return $self if $self->is_ready;
        my $runner = $self->{_la_runner} or return $self;
        my $resolve_now = $runner->_on_local_activity_cancel(
            $self, $self->{_la_seq}, $self->{_la_is_abandon}, $self->{_la_wait});
        if ($resolve_now) {
            $self->fail(Temporalio::Exception::Cancelled->new(
                message => 'Local activity cancelled',
            ));
        }
        return $self;
    }

    # _force_cancel: whole-workflow cancel (the primary-task cancel always raises,
    # spec section 10.3 cancel chain — unlike an explicit ->cancel it does not
    # honour wait_cancellation_completed). Emits the cancel command (unless
    # abandon) and fails the future Cancelled now.
    sub _force_cancel ($self) {
        return $self if $self->is_ready;
        my $runner = $self->{_la_runner};
        $runner->_force_local_activity_cancel(
            $self->{_la_seq}, $self->{_la_is_abandon}) if $runner;
        $self->fail(Temporalio::Exception::Cancelled->new(
            message => 'Local activity cancelled',
        ));
        return $self;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::Runner - the deterministic per-run workflow scheduler

=head1 SYNOPSIS

    use Temporalio::Workflow::Runner;

    my $runner = Temporalio::Workflow::Runner->new(
        workflow_class => 'My::Workflow::Greeting',
    );

    my $completion = $runner->process_activation($activation);
    # $completion is a coresdk WorkflowActivationCompletion proto

=head1 DESCRIPTION

One instance per workflow run (the dispatcher caches them by run id; the cache
lands in P3.6). The runner applies an activation's jobs, drives the workflow
C<:Run> body via manually-resolved L<Temporalio::Workflow::Future> objects
(B<never> via IO::Async timers or the wall clock — spec section 10.3), buffers
the commands the body emits, and drains them into a
C<WorkflowActivationCompletion> proto.

The workflow body runs under a dynamically-scoped C<$CURRENT> pointer (set with
L<Syntax::Keyword::Dynamically>, not C<local>, because the scope must survive
an C<await> — spec section 16.1) so that the C<Temporalio::Workflow::> context
functions (C<now>, C<time>, C<is_replaying>, C<info>, C<random>, ...) resolve
to the active runner.

=head2 Determinism

C<now>/C<time> derive from the activation timestamp, never the OS clock.
C<random> returns a L<Math::Random::ISAAC::XS> generator seeded from the
C<InitializeWorkflow> job's C<randomness_seed> (not the run id), so two runs
with the same seed produce the same sequence (spec test T-wf-10). An
C<UpdateRandomSeed> activation job re-seeds the generator. C<logger> returns a
L<Temporalio::Workflow::Logger> that suppresses output while replaying (T-wf-9),
and C<patched> / C<deprecate_patch> implement safe workflow versioning: on a
fresh run they emit a C<SetPatchMarker> command and return true; during replay
they return true only when the server sent a C<NotifyHasPatch> for the id. Each
patch answer is memoized so it is deterministic across the run.

=head2 Scope

Handles C<InitializeWorkflow>, activity scheduling
(C<execute_activity>/C<start_activity> -> C<ScheduleActivity> command +
C<ResolveActivity> job, P3.4), timers (C<start_timer>/C<sleep> -> C<StartTimer>
command + C<FireTimer> job, with C<CancelTimer> on Future cancel, P3.5),
C<wait_condition> (a predicate re-checked after each job set is applied,
optionally racing a timeout timer, P4.3), and the
success completion outcome. Each activity is tracked by its command C<seq> in a
pending-Futures map and resolved imperatively when the matching
C<ResolveActivity> job arrives (completed -> C<< ->done >>, failed/cancelled ->
C<< ->fail >> with the exception mapped from the Failure proto). Each timer is
tracked likewise and resolved on its C<FireTimer> job (C<< ->done >>) or, when
the timer Future is cancelled, removed and failed with a
L<Temporalio::Exception::Cancelled> after emitting C<CancelTimer>.

=head2 Completion-outcome decision table (spec section 10.3 step 6)

C<_build_completion> routes the run outcome to one of:

=over 4

=item *

A non-determinism error this activation (e.g. a C<ResolveActivity> for a
sequence the workflow never emitted) — a workflow B<task> failure by default,
or C<FailWorkflowExecution> when C<nondeterminism_as_workflow_fail> is set
(T-wf-13).

=item *

A C<continue_as_new> control signal (L<Temporalio::Workflow::ContinueAsNew>)
escaping C<:Run> — C<ContinueAsNewWorkflowExecution> carrying the new args and
type/task-queue/policy overrides (T-wf-8).

=item *

A L<Temporalio::Exception::Cancelled> escaping after a C<CancelWorkflow> job —
C<CancelWorkflowExecution> (NOT a failure) (T-wf-12).

=item *

A Temporal failure exception (any C<Temporalio::Exception::*>) or a class
listed in C<workflow_failure_exception_types> — C<FailWorkflowExecution>
(T-wf-15b/c).

=item *

Any other exception (a plain C<die>, a foreign class not listed) — the entire
completion is C<failed>: a workflow B<task> failure the server retries
(T-wf-15a).

=item *

A normal return — C<CompleteWorkflowExecution { result }> (T-wf-11).

=back

Signals/queries and the dispatcher's eviction fast path land in later phases.

=head2 Sequence numbers

Command sequence numbers (spec section 10.3) are workflow-scoped, monotonic
from 1, allocated at command-emission time and persisted across activations.
Each command type allocates from its OWN seq space: activities and timers each
start at 1 independently (MUST-match sdk-python C<_next_seq("activity")> vs
C<_next_seq("timer")>; sdk-ruby C<@activity_counter> vs C<@timer_counter>), so a
workflow's first activity and first timer are both seq 1. The command buffer, by
contrast, holds only the current activation's commands (the worker returns one
completion per activation).

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Workflow::Runner->new(
        workflow_class => ...,
        run_id => ...,
        payload_converter => ...,
        failure_converter => ...,
        task_queue => ...,
        workflow_failure_exception_types => ...,
        nondeterminism_as_workflow_fail => ...,
    );

Constructs a Temporalio::Workflow::Runner. Named parameters:

=over 4

=item C<workflow_class>

(required)

=item C<run_id>

(optional, default C<undef>)

=item C<payload_converter>

(optional, default C<undef>)

=item C<failure_converter>

(optional, default C<undef>)

=item C<task_queue>

(optional, default C<undef>)

=item C<workflow_failure_exception_types>

(optional, default C<[]>)

=item C<nondeterminism_as_workflow_fail>

(optional, default C<0>)

=back

=head1 METHODS

=head2 activation_time

Returns the timestamp of the activation currently being applied.

=head2 evict

Evicts the run from cache, cancelling any in-flight handler/awaitable Futures.

=head2 get_external_workflow_handle

Constructs a L<Temporalio::Workflow::ExternalWorkflowHandle> for an arbitrary
running workflow by id (spec section 20). A synchronous, non-command
constructor; the handle's C<signal>/C<cancel> emit the external-workflow
commands.

=head2 info

Returns the workflow info hash (run id, workflow type, namespace, etc.) for the run.

=head2 is_replaying

Returns true while the current activation is replaying history.

=head2 logger

Returns the run's replay-aware workflow logger.

=head2 patched

Implements the C<patched>/C<deprecate_patch> logic against history, emitting patch markers as needed.

=head2 process_activation

Applies one workflow activation (its jobs) against the workflow instance and returns the resulting completion (its buffered commands).

=head2 random

Returns the run's deterministic RNG seeded from the activation randomness seed.

=head2 run_id

Returns the run id of the workflow execution.

=head2 schedule_activity

Emits a ScheduleActivity command and returns the cancellable awaitable that resolves when the activity is resolved.

=head2 schedule_local_activity

Emits a ScheduleLocalActivity command (sharing the activity seq space and pending-activity map) and returns the single stable cancellable awaitable that resolves on the local activity's terminal outcome (spec section 21). The backoff-to-server-timer retry loop is owned here: a C<backoff> resolution starts a timer and re-schedules under a new seq when it fires, leaving the returned future untouched.

=head2 start_child_workflow

Emits a StartChildWorkflowExecution command and returns the start awaitable that resolves to a L<Temporalio::Workflow::ChildWorkflowHandle> once the child has started (spec section 18).

=head2 start_timer

Emits a StartTimer command and returns the cancellable awaitable that resolves when the timer fires.

=head2 upsert_search_attributes

Emits an UpsertWorkflowSearchAttributes command for the given typed updates (spec section 24) and updates the C<info-E<gt>{search_attributes}> view, converting every value before buffering so a conversion failure leaves no partial command. Empty updates emit no command; an untyped update raises L<Temporalio::Exception::Argument>.

=head2 upsert_memo

Emits a ModifyWorkflowProperties command for the given memo updates (spec section 24) and updates the C<info-E<gt>{memo}> view; an undef value removes the key (a null Payload). Empty updates emit no command; values are converted before buffering so a conversion failure leaves no partial command.

=head2 wait_condition

Registers a predicate to be re-checked as activations are applied, returning an awaitable that resolves when it holds.

=head2 workflow_type

Returns the workflow type name of the execution.

=cut
