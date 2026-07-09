# ABOUTME: The deterministic workflow Runner (spec section 10.3) — one instance
# ABOUTME: per workflow run. Applies activation jobs, drives the workflow body
# ABOUTME: via manually-resolved Futures (NEVER IO::Async), buffers commands.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

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
use Temporalio::Interceptor::Headers ();
use Temporalio::Core::Proto ();
use Temporalio::Exception ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Exception::ChildWorkflow ();
use Temporalio::Exception::WorkflowAlreadyStarted ();
use Temporalio::Exception::Timeout ();
use Temporalio::Exception::Nondeterminism ();
use Temporalio::Exception::Workflow::NoRunner ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::ReadOnly ();
use Temporalio::Exception::NexusOperation ();
use Temporalio::Common::Options ();
use Temporalio::Common::SearchAttributeUpdate ();
use Temporalio::Worker::Interceptor ();          # build_workflow_inbound + Input::*
use Temporalio::Worker::_RootWorkflowInbound ();
use Temporalio::Worker::_RootWorkflowOutbound ();

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

    # Whether the backing worker enabled the local-activity path (worker.rb rule:
    # workflows && activities registered). Defaults TRUE so the replay harness and
    # in-process tests keep scheduling LAs; the live worker injects the real value.
    # When false, schedule_local_activity raises a clean error at the call site
    # instead of emitting a ScheduleLocalActivity command core would drop, which
    # left the workflow hung forever (and SEGV'd at teardown pre-B4) (#9).
    field $local_activities_enabled :param = 1;

    # Worker versioning (spec §29.1): true when the worker runs in versioned
    # mode, so a successful completion may carry the per-workflow
    # VersioningBehavior (field 7). Core rejects a versioning_behavior from a
    # non-versioned worker, so this defaults off.
    field $report_versioning_behavior :param = 0;

    # The combined worker interceptor list (client-supplied then worker-supplied,
    # spec section 27.2). Folded over a root impl once the instance exists to
    # form $workflow_inbound; execute_workflow / handle_signal / handle_query /
    # handle_update all flow through that chain to the real handler (#10: the
    # chain was built by Worker.pm but the dispatch path never called it). The
    # replay harness defaults it empty (no interceptors).
    field $interceptors :param = [];

    field $instance;                 # the workflow Definition instance
    field $workflow_inbound;         # the built workflow-inbound interceptor chain
    field $workflow_outbound;        # the workflow-outbound chain init() produced (spec R71)
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

    # Nexus operations use a SEPARATE seq space from activities, timers, child
    # workflows, and external signals/cancels (spec section 26.3; MUST-match
    # sdk-python _next_seq("nexus_operation")): a workflow's first nexus operation
    # is seq 1 in its own space. Each ScheduleNexusOperation is matched in two
    # stages on the corresponding ResolveNexusOperationStart then
    # ResolveNexusOperation job (mirrors the child-workflow two-stage shape).
    field $nexus_operation_seq_counter = 0;

    # Pending nexus operation handles keyed by their ScheduleNexusOperation seq:
    # { seq => $handle }. Each Temporalio::Workflow::NexusOperationHandle owns a
    # start Future and a result Future, resolved imperatively in two stages (spec
    # section 26.3): an async start (operation_token) or sync start (started_sync)
    # ->dones the start Future and KEEPS the seq mapped (the result job still
    # comes); a start `failed` pops the seq and fails the start Future (no result
    # job follows); the terminal ResolveNexusOperation pops the seq and settles
    # the result Future.
    field %pending_nexus_operations;

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

    # Activity seqs (regular or local; they share one seq space) whose
    # RequestCancel command has already been emitted, so any further cancel of
    # the same seq is a command-level no-op (spec R53 / finding L10: at most
    # one RequestCancelLocalActivity per LA seq; the same guard protects the
    # regular arm and the wait-then-force overlap on evict). Cleared when the
    # seq de-registers (resolve-now cancel or terminal resolution). Run-scoped.
    field %activity_cancel_requested;

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

    # "Terminal command already emitted" guard (B2 C-CANCEL-CMD, bugs #6/#7).
    # RUN-scoped (persists across activations, unlike the per-activation @commands
    # buffer): set the first time a workflow-terminal command (Complete / Cancel /
    # Fail / ContinueAsNew) is pushed. After the :Run Future settles, core may
    # still deliver further activations (e.g. the ResolveActivity for an activity
    # that a CancelWorkflow (#6) or a Future->wait_any loser-cancel (#7) left
    # pending. The outcome decision table runs every activation, so without this
    # guard the still-settled :Run Future re-pushed its terminal command, yielding
    # an invalid [..., Cancel, Cancel] / [..., Complete, Complete] sequence that
    # core rejects (and that SEGVs the live worker on the #7 path). The guard
    # emits at most one workflow-terminal command across the run.
    field $workflow_terminal_emitted = 0;

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

    # Read-only guard depth (spec section 19.2 + step R24 / sdk-python
    # _as_read_only): while > 0 the runner is executing a synchronous read-only
    # block (an update validator or a :Query handler), so any command-emitting
    # call MUST throw Temporalio::Exception::ReadOnly (via _assert_writable)
    # rather than buffer a command. A counter (not a bool) so nesting is safe.
    field $read_only_depth = 0;

    # Durable-scheduler suppression depth (spec section 27.4 /
    # Temporalio::Workflow::Unsafe::durable_scheduler_disabled): while > 0 the
    # runner is executing a block that must not record on / yield to the durable
    # scheduler (OpenTelemetry span attach/extract that touches a mutex or real
    # wall-clock time). A counter (not a bool) so nesting is safe. Read via
    # durable_scheduler_suppressed; set with Syntax::Keyword::Dynamically so it
    # unwinds across an await.
    field $durable_suppress_depth = 0;

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

    # Monotonic arrival stamp for buffered signals (spec R26): each buffered
    # entry is [stamp, job]. The buffer is keyed by name, so without the stamp
    # the drain would visit names in hash order and scramble CROSS-name arrival
    # order; sdk-python applies init-activation signals in job order
    # (_workflow_instance.py activate() set 1), so the drain sorts by stamp.
    field $buffered_signal_arrival = 0;

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

    # The static info() fields seeded from the InitializeWorkflow job (spec R36
    # / finding A5): workflow_id and attempt, seeded once in _apply_initialize
    # so every init-derived info() field is sourced from this one struct.
    # Field names MUST-match Python's workflow.info() (sdk-python
    # workflow/_context.py Info: workflow_id, attempt, task_queue, ...), and
    # the sourcing matches Python's Info construction (worker/_workflow.py):
    # workflow_id/attempt from the init job, task_queue from the worker (the
    # $task_queue constructor param above), run_id from the activation,
    # namespace from the worker.
    field %init_info;

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

    # The worker-level failure-routing options (spec R14+R15, findings
    # A1/ADJ2): readers so the plumbing tests can assert both options actually
    # arrived; the live path silently dropped them pre-fix.
    method workflow_failure_exception_types { return $workflow_failure_exception_types }
    method nondeterminism_as_workflow_fail  { return $nondeterminism_as_workflow_fail ? 1 : 0 }

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

    # info routes through the workflow-outbound interceptor chain (spec R71;
    # MUST-match sdk-python worker/_interceptor.py:435-437). The chain exists
    # from _apply_initialize on; a call before then (e.g. the logger firing
    # while a signal is buffered ahead of InitializeWorkflow) reads the view
    # directly; Python cannot be called that early (its _Runtime is only set
    # once the instance, and with it the chain, exists). The Input carries
    # only the private `_root` coderef: Python's outbound info() takes no
    # input, a documented spec §0 surface deviation (see WorkflowOutbound).
    method info {
        return $self->_root_info unless defined $workflow_outbound;
        return $workflow_outbound->info(
            Temporalio::Worker::Interceptor::Input::Info->new(
                _root => sub { $self->_root_info }));
    }

    # The real info view the chain root reads (spec section 10.4 / R36).
    method _root_info {
        return {
            # The init-derived static fields (workflow_id, attempt), seeded in
            # _apply_initialize (spec R36 / finding A5; Python-parity names).
            %init_info,
            run_id        => $run_id,
            workflow_type => $workflow_type,
            # The workflow execution's task queue, worker-injected at
            # construction (Python sources Info.task_queue from the worker
            # too; the activation carries no queue).
            task_queue    => $task_queue,
            # The workflow namespace (spec section 20): read by
            # get_external_workflow_handle to populate the
            # NamespacedWorkflowExecution arm of signal/cancel commands.
            namespace     => $namespace,
            # The patch ids the server has notified for this run (spec section
            # 10.3 "record in workflow info"). Sorted for a stable view.
            patches       => [ sort keys %patches_notified ],
            # The in-workflow search-attribute / memo views (spec section 24),
            # seeded from start-time values and kept in sync by upsert_*.
            # Sourced through the R54 readers so info and the readers cannot
            # drift (both copy, so callers cannot mutate the runner's view).
            search_attributes => $self->search_attributes,
            memo              => $self->memo,
        };
    }

    # The Workflow::memo / Workflow::search_attributes readers (spec R54 /
    # finding A6; the archived v1 spec promises both at lines 1869-1870). Each
    # reads the very field its upsert_* counterpart writes (%memo_view /
    # %search_attributes_view, seeded from the InitializeWorkflow job in
    # _apply_initialize), so a read after an upsert always sees the update.
    # Returned as fresh copies per call, matching the info() copy contract.
    method memo { return { %memo_view } }

    method search_attributes { return { %search_attributes_view } }

    # patched($patch_id, deprecated => $bool) -> a boolean: should the workflow
    # take the "with change" branch? (spec section 10.4 versioning; MUST-match
    # sdk-python workflow_patch). The answer is memoized per run so it is stable
    # and the SetPatchMarker is emitted at most once. On a fresh (non-replay)
    # execution the patch is always in use; during replay it is in use only when
    # the server notified it (it was present in history). Emitting the marker
    # tells the server this run took the patched branch.
    method patched ($patch_id, %opts) {
        # Before the memoization check, so a read-only caller cannot mutate
        # %patches_memoized (step R24, finding R8; sdk-python asserts at the
        # head of workflow_patch).
        $self->_assert_writable('patched');
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

    # The known option keys for the two activity call sites, and the ONE
    # strictness rule they share (spec R35, finding A2; aligned with the client
    # surface R44 and typed missing-arg R55 so the SDK has a single strictness
    # story): an unknown key raises Temporalio::Exception::Argument (a typo
    # must never vanish silently), and at least one of start_to_close_timeout /
    # schedule_to_close_timeout is required (Python parity; without one the
    # activity retries forever and the call hangs). Validation runs BEFORE any
    # command state changes, so a rejected call burns no seq.
    my %ACTIVITY_OPTION_KEYS = map { $_ => 1 } qw(
        activity_type args task_queue activity_id
        schedule_to_close_timeout schedule_to_start_timeout
        start_to_close_timeout heartbeat_timeout
        retry_policy cancellation_type priority summary headers
    );
    # Local activities: no task_queue (core runs the LA in-process), no
    # heartbeat_timeout (LAs do not heartbeat at the lang level), and no
    # priority (the ScheduleLocalActivity proto has no priority field), but
    # local_retry_threshold in addition.
    my %LOCAL_ACTIVITY_OPTION_KEYS = map { $_ => 1 } qw(
        activity_type args activity_id
        schedule_to_close_timeout schedule_to_start_timeout
        start_to_close_timeout
        retry_policy local_retry_threshold cancellation_type summary headers
    );

    sub _validate_activity_options ($what, $known, $opts) {
        Temporalio::Common::Options::assert_known_keys($what, $opts, $known);
        # activity_type is required (spec R55, finding A14): a missing
        # workflow-context argument raises the same typed
        # Temporalio::Exception::Argument as the strictness rules above and
        # below, catchable by class, never a plain string die.
        Temporalio::Common::Options::assert_required_keys(
            $what, $opts, ['activity_type']);
        Temporalio::Common::Options::assert_activity_timeouts($what, $opts);
        return;
    }

    # schedule_activity(%opts) -> a Temporalio::Workflow::Future resolved when
    # the matching ResolveActivity job arrives. Allocates the next seq, builds
    # the ScheduleActivity command, buffers it, and registers the pending
    # Future. The Workflow:: functional surface (execute_activity/start_activity)
    # delegates here. %opts mirrors the spec section 10.2 kwargs:
    #   activity_type (required), args (arrayref), task_queue, activity_id,
    #   schedule_to_close_timeout, schedule_to_start_timeout,
    #   start_to_close_timeout, heartbeat_timeout (all seconds), retry_policy
    #   (Temporalio::Common::RetryPolicy), cancellation_type (string),
    #   priority (Temporalio::Common::Priority), summary (string), headers.
    method schedule_activity (%opts) {
        $self->_assert_writable('execute_activity/start_activity');
        # Option strictness first (spec R35 finding A2, spec R55 finding A14):
        # unknown keys, a missing activity_type, and a missing required
        # timeout raise typed, before the seq is allocated (and before any
        # interceptor runs).
        _validate_activity_options('execute_activity/start_activity',
            \%ACTIVITY_OPTION_KEYS, \%opts);
        # Route through the workflow-outbound interceptor chain (spec R71,
        # parity finding 1; MUST-match sdk-python worker/_interceptor.py:
        # 453-459 start_activity). Input shape follows the client convention
        # (Client.pm start_workflow): the Python-parity primary field
        # (activity), writable args/headers, and the remaining scheduling
        # options bundled as kwargs for the chain root to rebuild from.
        my $input =
            Temporalio::Worker::Interceptor::Input::StartActivity->new(
                activity => delete $opts{activity_type},
                args     => delete($opts{args}) // [],
                headers  => { %{ delete($opts{headers}) // {} } },
                kwargs   => { %opts },
                _root    => sub { $self->_root_schedule_activity($_[0]) },
            );
        return $workflow_outbound->execute_activity($input);
    }

    # The chain root: emit ScheduleActivity from the (possibly
    # interceptor-mutated) input (spec R71).
    method _root_schedule_activity ($input) {
        my %opts = (
            activity_type => $input->get('activity'),
            args          => $input->args,
            headers       => $input->headers,
            %{ $input->get('kwargs') },
        );
        my $activity_type = $opts{activity_type};

        my $seq = ++$activity_seq_counter;  # activity seq space, from 1.

        # Convert the activity arguments to payloads (MUST-match sdk-python:
        # arguments converted before the command is built so a converter error
        # surfaces at the call site, not later).
        my @args = map { $payload_converter->to_payload($_) }
            (($opts{args} // [])->@*);

        # summary -> the WorkflowCommand user_metadata.summary Payload,
        # converted up front for the same call-site-error reason (spec R69 /
        # finding A17; MUST-match sdk-python _workflow_instance.py:3155-3158,
        # which sets command.user_metadata.summary only when a summary was
        # given). The LA and nexus arms already follow this convention.
        my $summary = defined $opts{summary}
            ? $payload_converter->to_payload($opts{summary}) : undef;

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

        # priority (a Temporalio::Common::Priority) -> the ScheduleActivity
        # priority proto, only when the caller passed one: an absent option
        # must leave the field unset so the server inherits from the calling
        # workflow (spec R69 / finding A17; MUST-match sdk-python
        # _workflow_instance.py:3180-3183, command.schedule_activity.priority;
        # the same ->to_proto contract as start_workflow's priority kwarg).
        if (defined(my $priority = $opts{priority})) {
            $fields{priority} = $priority->to_proto;
        }

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

        # Headers: { name => value } -> { name => Payload } when non-empty. A
        # value already shaped as a Payload (as context propagation forwards the
        # start headers it read off the workflow-inbound hook) passes through
        # untouched — re-encoding it would double-encode (#10
        # C-ICEPT-ACTIVITY-HEADERS GAP B). One contract, shared with the inbound
        # paths, in Temporalio::Interceptor::Headers.
        if (my $headers = $opts{headers}) {
            if (%$headers) {
                $fields{headers} = Temporalio::Interceptor::Headers::to_payload_map(
                    $payload_converter, $headers);
            }
        }

        push @commands,
            Temporalio::Workflow::Commands::schedule_activity(\%fields, $summary);

        # ABANDON (ActivityCancellationType=2): on cancel, the workflow stops
        # waiting WITHOUT asking core to cancel the activity — so the Future's
        # cancel emits NO RequestCancelActivity (proto comment: "Do not request
        # cancellation of the activity and immediately report cancellation to
        # the workflow"). TRY_CANCEL (0) / WAIT_CANCELLATION_COMPLETED (1) emit
        # RequestCancelActivity so core forwards the cancel to the running
        # activity (MUST-match sdk-python _ActivityHandle._apply_cancel_command).
        my $is_abandon = $fields{cancellation_type} == 2 ? 1 : 0;
        my $wait       = $fields{cancellation_type} == 1 ? 1 : 0;

        # Register the pending Future the body awaits; the runner resolves it
        # imperatively from the ResolveActivity job (never via IO::Async). The
        # _ActivityFuture cancel hook delegates to _on_activity_cancel, which
        # honours the cancellation_type exactly as the local-activity arm does
        # (spec R12 / finding R7): try_cancel/abandon resolve Cancelled now
        # (try_cancel also emits RequestCancelActivity and records the seq so
        # the later stale ResolveActivity{cancelled} from core is tolerated);
        # wait_cancellation_completed emits the cancel but PARKS — the future
        # stays registered and resolves only from the delivered ResolveActivity,
        # carrying the real outcome.
        my $future = Temporalio::Workflow::Runner::_ActivityFuture->_new_activity(
            seq        => $seq,
            runner     => $self,
            is_abandon => $is_abandon,
            wait       => $wait,
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
        # Option strictness first (spec R35, finding A2): caller-argument
        # errors surface before the worker-configuration guard below, and
        # before any command state changes.
        _validate_activity_options(
            'execute_local_activity/start_local_activity',
            \%LOCAL_ACTIVITY_OPTION_KEYS, \%opts);

        # Boundary guard (#9): a worker with no registered activities builds with
        # enable_local_activities => 0, so core silently drops any
        # ScheduleLocalActivity command and the workflow hangs forever (pre-B4 it
        # SEGV'd the worker at teardown). Fail the call cleanly here instead, so a
        # regression surfaces as a workflow-task error naming the cause, never a
        # hang or a crash.
        unless ($local_activities_enabled) {
            die "Temporalio::Workflow::Runner: execute_local_activity/"
              . "start_local_activity requires the worker to register the "
              . "activity, but this worker has no activities registered "
              . "(local activities run the worker's own activity code). Add the "
              . "activity to the worker's 'activities' list (#9).\n";
        }

        # Route through the workflow-outbound interceptor chain (spec R71;
        # MUST-match sdk-python worker/_interceptor.py:469-475
        # start_local_activity); same input shape as schedule_activity.
        my $input =
            Temporalio::Worker::Interceptor::Input::StartLocalActivity->new(
                activity => delete $opts{activity_type},
                args     => delete($opts{args}) // [],
                headers  => { %{ delete($opts{headers}) // {} } },
                kwargs   => { %opts },
                _root => sub { $self->_root_schedule_local_activity($_[0]) },
            );
        return $workflow_outbound->execute_local_activity($input);
    }

    # The chain root: emit ScheduleLocalActivity from the (possibly
    # interceptor-mutated) input (spec R71).
    method _root_schedule_local_activity ($input) {
        my %opts = (
            activity_type => $input->get('activity'),
            args          => $input->args,
            headers       => $input->headers,
            %{ $input->get('kwargs') },
        );
        # Defined-ness is guaranteed by _validate_activity_options (spec R55).
        my $activity_type = $opts{activity_type};

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

        # Pass-through Payloads, never re-encoded (#10 GAP B); shared contract in
        # Temporalio::Interceptor::Headers.
        if (my $headers = $opts{headers}) {
            if (%$headers) {
                $base{headers} = Temporalio::Interceptor::Headers::to_payload_map(
                    $payload_converter, $headers);
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

    # _activity_cancel_core($seq, %opt) — the ONE wait-type cancel arm shared by
    # regular activities and local activities (spec R12+R52+R53; findings
    # R7/L8/L10). Emits the arm's RequestCancel command AT MOST ONCE per seq
    # (%activity_cancel_requested, the R53 sent-flag; abandon never emits), then
    # decides park-vs-resolve:
    #   * wait_cancellation_completed PARKS (returns 0): the seq stays
    #     registered in %pending_activities so the later ResolveActivity is
    #     matched and delivers the REAL outcome — cancelled, completed, or
    #     failed. Python parity (../sdk-python worker/_workflow_instance.py,
    #     run_activity): on cancel Python emits the command and keeps awaiting
    #     the shielded result future; core, not lang, differentiates the types.
    #   * try_cancel / abandon resolve now (returns 1): de-register, and record
    #     the seq per %opt{record_stale} so the later stale
    #     ResolveActivity{cancelled} from core is tolerated.
    #   * force => 1 (the whole-workflow cancel chain and evict, spec R52 /
    #     finding L8) ignores the wait type: cancellation always resolves now,
    #     so a parked frame unwinds and the run is always releasable.
    # %opt: is_local, is_abandon, wait, force, record_stale.
    method _activity_cancel_core ($seq, %opt) {
        unless ($opt{is_abandon} || $activity_cancel_requested{$seq}++) {
            push @commands, $opt{is_local}
                ? Temporalio::Workflow::Commands::request_cancel_local_activity(
                    $seq)
                : Temporalio::Workflow::Commands::request_cancel_activity($seq);
        }
        return 0 if $opt{wait} && !$opt{is_abandon} && !$opt{force};
        delete $pending_activities{$seq};
        delete $local_activity_state{$seq} if $opt{is_local};
        delete $activity_cancel_requested{$seq};
        $cancelled_activity_seqs{$seq} = 1 if $opt{record_stale};
        return 1;
    }

    # _on_activity_cancel($seq, $is_abandon, $wait) — the runner side of a
    # REGULAR activity's Future ->cancel (spec R12 / finding R7). Returns true
    # when the caller (the _ActivityFuture) should resolve Cancelled
    # IMMEDIATELY (try_cancel/abandon), or false when it should PARK
    # (wait_cancellation_completed: the cancel command is emitted now, but the
    # future stays pending until the delivered ResolveActivity resolves it with
    # the real outcome — matching the local-activity arm and Python).
    method _on_activity_cancel ($seq, $is_abandon, $wait) {
        # Already de-registered (evict cleared the maps, or a late cancel after
        # resolve-now): nothing to emit; resolve Cancelled so the awaiting
        # frame always unwinds.
        return 1 unless $pending_activities{$seq};
        return $self->_activity_cancel_core($seq,
            is_local     => 0,
            is_abandon   => $is_abandon,
            wait         => $wait,
            # The regular arm records the stale-resolve tolerance for abandon
            # too (core reports an abandoned activity cancelled immediately and
            # still sends the resolution).
            record_stale => 1,
        );
    }

    # _force_activity_cancel($seq, $is_abandon) — the whole-workflow cancel
    # chain / evict path for a REGULAR activity (spec section 10.3; spec R52
    # convention shared with _force_local_activity_cancel): ignore the wait
    # type, emit RequestCancelActivity at most once (unless abandon), record
    # the cancelled seq, de-register. The future itself is failed Cancelled by
    # the caller (_ActivityFuture::_force_cancel).
    method _force_activity_cancel ($seq, $is_abandon) {
        return unless $pending_activities{$seq};
        $self->_activity_cancel_core($seq,
            is_local     => 0,
            is_abandon   => $is_abandon,
            force        => 1,
            record_stale => 1,
        );
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
    #   * In-flight, try_cancel/wait: emit RequestCancelLocalActivity AT MOST
    #     ONCE (spec R53 / finding L10); try_cancel resolves now (T-local-10),
    #     wait parks (T-local-11).
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

        # Already de-registered (evict cleared the maps, or a late cancel after
        # resolve-now): nothing to emit; resolve Cancelled so the awaiting
        # frame always unwinds (pre-fix this fell through to the wait branch
        # and parked forever — spec R52 / finding L8).
        return 1 unless $pending_activities{$seq};

        return $self->_activity_cancel_core($seq,
            is_local   => 1,
            is_abandon => $is_abandon,
            wait       => $wait,
            # The LA arm records the stale-resolve tolerance only for the
            # emitting types (abandon LAs get no later resolution to tolerate).
            record_stale => !$is_abandon,
        );
    }

    # _force_local_activity_cancel($seq, $is_abandon) — the whole-workflow
    # cancel chain / evict path for an IN-FLIGHT LA (spec section 10.3): ignore
    # the wait type, emit RequestCancelLocalActivity at most once (unless
    # abandon; the sent-flag also suppresses a duplicate after an earlier
    # wait-type ->cancel — spec R53), record the cancelled seq, and de-register.
    # The future itself is failed Cancelled by the caller. (Backing-off LAs are
    # handled separately in _apply_cancel_workflow.)
    method _force_local_activity_cancel ($seq, $is_abandon) {
        $self->_activity_cancel_core($seq,
            is_local     => 1,
            is_abandon   => $is_abandon,
            force        => 1,
            record_stale => !$is_abandon,
        );
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
        $opts{workflow_type}
            // die "Temporalio::Workflow::Runner: start_child_workflow needs a "
                 . "workflow_type";

        # Route through the workflow-outbound interceptor chain (spec R71;
        # MUST-match sdk-python worker/_interceptor.py:461-467
        # start_child_workflow); the Python-parity primary field is
        # `workflow`, args/headers are writable, the rest rides in kwargs.
        my $input =
            Temporalio::Worker::Interceptor::Input::StartChildWorkflow->new(
                workflow => delete $opts{workflow_type},
                args     => delete($opts{args}) // [],
                headers  => { %{ delete($opts{headers}) // {} } },
                kwargs   => { %opts },
                _root    => sub { $self->_root_start_child_workflow($_[0]) },
            );
        return $workflow_outbound->start_child_workflow($input);
    }

    # The chain root: emit StartChildWorkflowExecution from the (possibly
    # interceptor-mutated) input (spec R71).
    method _root_start_child_workflow ($input) {
        my %opts = (
            workflow_type => $input->get('workflow'),
            args          => $input->args,
            headers       => $input->headers,
            %{ $input->get('kwargs') },
        );
        my $workflow_type = $opts{workflow_type};

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

        # Headers / memo: { name => value } -> { name => Payload } when set.
        # Headers pass an already-Payload value through (#10 GAP B, shared
        # contract in Temporalio::Interceptor::Headers); memo values are raw
        # user data, always encoded once.
        if (my $h = $opts{headers}) {
            $fields{headers} = Temporalio::Interceptor::Headers::to_payload_map(
                $payload_converter, $h) if %$h;
        }
        if (my $m = $opts{memo}) {
            $fields{memo} = {
                map { $_ => $payload_converter->to_payload($m->{$_}) } keys %$m
            } if %$m;
        }

        # Search attributes -> proto when given, via the encoder shared with
        # the continue-as-new builder (spec R25).
        if (defined(my $sa = $opts{search_attributes})) {
            $fields{search_attributes} = _search_attributes_proto($sa);
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
    # later ResolveSignalExternalWorkflow settles it. In-flight cancellation is
    # shared with the external-handle arm via
    # _register_pending_external_signal (finding R10). Returns the Future the
    # $handle->signal caller awaits.
    method _signal_child_workflow ($handle, $name, %opts) {
        # Step R24 (finding R8): before the seq allocation, so a read-only
        # caller leaves no gap in the seq space (sdk-python "signal child
        # handle").
        $self->_assert_writable('signal child workflow handle');

        # Route through the workflow-outbound interceptor chain (spec R71;
        # field names MUST-match sdk-python worker/_interceptor.py:222-229
        # SignalChildWorkflowInput).
        my $input =
            Temporalio::Worker::Interceptor::Input::SignalChildWorkflow->new(
                signal            => $name,
                child_workflow_id => $handle->id,
                args              => delete($opts{args}) // [],
                headers           => { %{ delete($opts{headers}) // {} } },
                _root => sub { $self->_root_signal_child_workflow($_[0]) },
            );
        return $workflow_outbound->signal_child_workflow($input);
    }

    # The chain root: emit the child-targeted SignalExternalWorkflowExecution
    # from the (possibly interceptor-mutated) input (spec R71).
    method _root_signal_child_workflow ($input) {
        my $seq = ++$external_signal_seq_counter;

        my @args = map { $payload_converter->to_payload($_) }
            (($input->args // [])->@*);

        my %fields = (
            seq               => $seq,
            child_workflow_id => $input->get('child_workflow_id'),
            signal_name       => $input->get('signal'),
            (@args ? (args => [@args]) : ()),
        );
        # Pass-through Payloads, never re-encoded (#10 GAP B); shared contract in
        # Temporalio::Interceptor::Headers.
        if (my $h = $input->headers) {
            if (%$h) {
                $fields{headers} = Temporalio::Interceptor::Headers::to_payload_map(
                    $payload_converter, $h);
            }
        }

        push @commands,
            Temporalio::Workflow::Commands::signal_external_workflow_execution(
                \%fields);

        return $self->_register_pending_external_signal($seq);
    }

    # Register the pending signal Future for $seq and install the shared
    # in-flight cancellation hook. Both signal arms, child-targeted (spec
    # section 18) and external-handle (spec section 20), MUST behave
    # identically here: cancelling the returned Future before its resolve
    # emits CancelSignalWorkflow{seq} at most once and does NOT pre-emptively
    # settle it; the seq stays mapped so the eventual
    # ResolveSignalExternalWorkflow settles (or, post-cancel, is dropped by
    # the is_ready guard, spec section 20.2). Finding R10 (step-45 audit):
    # the child arm originally shipped without the hook, so a cancelled
    # pending child signal never emitted the cancel command; one shared
    # registration point keeps the two arms from drifting again.
    method _register_pending_external_signal ($seq) {
        my $future = Temporalio::Workflow::Future->new;
        $pending_external_signals{$seq} = $future;

        # The hook must NOT fail the Future here (cancelling a Future already
        # marks it ready/cancelled); we only emit the cancel command at most
        # once. A ready Future ignores ->cancel, so a post-resolve cancel
        # never reaches this hook.
        my $cancel_emitted = 0;
        $future->on_cancel(sub {
            return if $cancel_emitted;
            $cancel_emitted = 1;
            push @commands,
                Temporalio::Workflow::Commands::cancel_signal_workflow($seq);
        });

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
    # runner's namespace (never a user argument). In-flight cancellation is
    # shared with the child arm via _register_pending_external_signal (finding
    # R10): cancelling the returned Future before its resolve emits
    # CancelSignalWorkflow{seq} and does NOT pre-emptively settle it; the
    # eventual Resolve* still arrives (spec section 20.2 in-flight
    # cancellation; MUST-match sdk-python asyncio.shield +
    # cancel_signal_workflow). Returns the Future the $handle->signal caller awaits.
    method _signal_external_workflow ($workflow_id, $run_id, $name, %opts) {
        # Step R24 (finding R8): before the seq allocation (sdk-python "signal
        # external handle").
        $self->_assert_writable('signal external workflow handle');

        # Route through the workflow-outbound interceptor chain (spec R71;
        # field names MUST-match sdk-python worker/_interceptor.py:232-241
        # SignalExternalWorkflowInput).
        my $input =
            Temporalio::Worker::Interceptor::Input::SignalExternalWorkflow->new(
                signal          => $name,
                namespace       => $namespace,
                workflow_id     => $workflow_id,
                workflow_run_id => $run_id,
                args            => delete($opts{args}) // [],
                headers         => { %{ delete($opts{headers}) // {} } },
                _root => sub { $self->_root_signal_external_workflow($_[0]) },
            );
        return $workflow_outbound->signal_external_workflow($input);
    }

    # The chain root: emit the workflow_execution-arm
    # SignalExternalWorkflowExecution from the (possibly interceptor-mutated)
    # input (spec R71).
    method _root_signal_external_workflow ($input) {
        my $seq = ++$external_signal_seq_counter;

        my @args = map { $payload_converter->to_payload($_) }
            (($input->args // [])->@*);

        my %fields = (
            seq                => $seq,
            workflow_execution => {
                namespace   => $input->get('namespace'),
                workflow_id => $input->get('workflow_id'),
                run_id      => ($input->get('workflow_run_id') // ''),
            },
            signal_name        => $input->get('signal'),
            (@args ? (args => [@args]) : ()),
        );
        # Pass-through Payloads, never re-encoded (#10 GAP B); shared contract in
        # Temporalio::Interceptor::Headers.
        if (my $h = $input->headers) {
            if (%$h) {
                $fields{headers} = Temporalio::Interceptor::Headers::to_payload_map(
                    $payload_converter, $h);
            }
        }

        push @commands,
            Temporalio::Workflow::Commands::signal_external_workflow_execution(
                \%fields);

        return $self->_register_pending_external_signal($seq);
    }

    # Emit a RequestCancelExternalWorkflowExecution targeting an arbitrary
    # workflow (spec section 20) and register the pending cancel Future so a
    # later ResolveRequestCancelExternalWorkflow settles it. Draws from the
    # SEPARATE external-cancel seq space. A cancel request has no counter-cancel
    # ("there is no cancelling a cancel request" — spec section 20.2), so no
    # on_cancel hook is installed. Returns the Future the $handle->cancel caller
    # awaits.
    method _request_cancel_external_workflow ($workflow_id, $run_id, %opts) {
        # Step R24 (finding R8): before the seq allocation (sdk-python "cancel
        # external handle").
        $self->_assert_writable('cancel external workflow handle');
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

    # --- Nexus (spec section 26) --------------------------------------------

    # create_nexus_client(endpoint => ..., service => ...) -> a
    # Temporalio::Workflow::NexusClient bound to that endpoint + service (spec
    # section 26.1). A synchronous, non-command constructor (mirrors
    # get_external_workflow_handle): captures the endpoint/service plus the runner
    # reference and emits nothing. The returned client's start_operation /
    # execute_operation emit the ScheduleNexusOperation command through this
    # runner. Both endpoint and service are required.
    method create_nexus_client (%opts) {
        my $endpoint = $opts{endpoint}
            // die "Temporalio::Workflow::Runner: create_nexus_client needs an "
                 . "endpoint";
        my $service = $opts{service}
            // die "Temporalio::Workflow::Runner: create_nexus_client needs a "
                 . "service";
        require Temporalio::Workflow::NexusClient;
        return Temporalio::Workflow::NexusClient->new(
            endpoint => $endpoint,
            service  => $service,
            runner   => $self,
        );
    }

    # start_nexus_operation(endpoint => ..., service => ..., operation => ...,
    # arg => ..., %opts) -> the start Temporalio::Workflow::Future (->done with
    # the NexusOperationHandle once ResolveNexusOperationStart arrives). Mirrors
    # start_child_workflow's two-stage shape (spec section 26.3): allocates a
    # NEXUS seq (separate space), converts the SINGLE arg -> input Payload, the
    # three timeouts -> Duration, cancellation_type -> enum, summary ->
    # user_metadata, all BEFORE buffering the command (so a converter error
    # surfaces at the call site). Buffers one ScheduleNexusOperation (oneof arm
    # 21), registers a handle wrapping a start Future and a result Future in
    # %pending_nexus_operations{$seq} plus a cancel hook, and returns the start
    # Future. A pre-scheduled cancel (the run is already cancel-requested) raises
    # Cancelled immediately (spec section 26.3). %opts mirror spec section 26.1:
    #   schedule_to_close_timeout / schedule_to_start_timeout /
    #   start_to_close_timeout (seconds), cancellation_type (default
    #   wait_cancellation_completed), summary, headers (the nexus_header string
    #   map, NOT Temporal-header Payloads).
    method start_nexus_operation (%opts) {
        $self->_assert_writable('start_operation/execute_operation');
        $opts{endpoint}  // die
            "Temporalio::Workflow::Runner: start_nexus_operation needs an endpoint";
        $opts{service}   // die
            "Temporalio::Workflow::Runner: start_nexus_operation needs a service";
        $opts{operation} // die
            "Temporalio::Workflow::Runner: start_nexus_operation needs an operation";

        # Route through the workflow-outbound interceptor chain (spec R71;
        # field names MUST-match sdk-python worker/_interceptor.py:298-312
        # StartNexusOperationInput: the single payload option is `input`,
        # headers are the PLAIN string nexus_header map). The single `input`
        # value is read-only on the Input (only args/headers are writable,
        # spec section 27.1); the remaining options ride in kwargs.
        my $input =
            Temporalio::Worker::Interceptor::Input::StartNexusOperation->new(
                endpoint  => delete $opts{endpoint},
                service   => delete $opts{service},
                operation => delete $opts{operation},
                input     => delete $opts{arg},
                headers   => { %{ delete($opts{headers}) // {} } },
                kwargs    => { %opts },
                _root => sub { $self->_root_start_nexus_operation($_[0]) },
            );
        return $workflow_outbound->start_nexus_operation($input);
    }

    # The chain root: emit ScheduleNexusOperation from the (possibly
    # interceptor-mutated) input (spec R71).
    method _root_start_nexus_operation ($input_obj) {
        my %opts = (
            endpoint  => $input_obj->get('endpoint'),
            service   => $input_obj->get('service'),
            operation => $input_obj->get('operation'),
            arg       => $input_obj->get('input'),
            headers   => $input_obj->headers,
            %{ $input_obj->get('kwargs') },
        );
        my $endpoint  = $opts{endpoint};
        my $service   = $opts{service};
        my $operation = $opts{operation};

        my $seq = ++$nexus_operation_seq_counter;  # nexus seq space, from 1.

        # The proto carries a SINGLE input Payload (not a repeated list), so
        # convert exactly one arg. Convert up front (parity with
        # schedule_activity: a converter error must surface at the call site).
        my $input = $payload_converter->to_payload($opts{arg});

        my %fields = (
            seq       => $seq,
            endpoint  => $endpoint,
            service   => $service,
            operation => $operation,
            input     => $input,
            # cancellation_type: spec string -> NexusOperationCancellationType
            # enum number, DEFAULT wait_cancellation_completed (0) — the Nexus
            # proto zero, unlike activities/children whose default is non-zero.
            cancellation_type =>
                _nexus_cancellation_type_number($opts{cancellation_type}),
        );

        # The three timeouts: seconds -> google.protobuf.Duration, only when set.
        my %timeout_field = (
            schedule_to_close_timeout => 'schedule_to_close_timeout',
            schedule_to_start_timeout => 'schedule_to_start_timeout',
            start_to_close_timeout    => 'start_to_close_timeout',
        );
        for my $opt (keys %timeout_field) {
            next unless defined $opts{$opt};
            $fields{ $timeout_field{$opt} } = _duration($opts{$opt});
        }

        # headers -> nexus_header: a PLAIN string -> string map transmitted to
        # the (possibly external) Nexus handler as-is — NOT Temporal-header
        # Payloads (spec section 26.1). Stringify values defensively.
        if (my $h = $opts{headers}) {
            if (%$h) {
                $fields{nexus_header} = { map { $_ => "$h->{$_}" } keys %$h };
            }
        }

        # summary -> the WorkflowCommand user_metadata.summary Payload (the
        # ScheduleNexusOperation message itself has no summary field).
        my $summary = defined $opts{summary}
            ? $payload_converter->to_payload($opts{summary}) : undef;

        push @commands,
            Temporalio::Workflow::Commands::schedule_nexus_operation(
                \%fields, $summary);

        # cancellation_type governs cancel behaviour (spec section 26.3, mirrors
        # the child-workflow semantics over NexusOperationCancellationType):
        #   wait_cancellation_completed (0, default): emit the cancel command but
        #     stay parked on `result` (observe cancellation on the later resolve).
        #   abandon (1): emit NO cancel command; stop waiting immediately.
        #   try_cancel (2): emit the cancel command AND report cancellation now.
        #   wait_cancellation_requested (3): emit the cancel command but stay
        #     parked on `result`.
        my $ct         = $fields{cancellation_type};
        my $is_abandon = $ct == 1 ? 1 : 0;
        my $report_now = ($ct == 1 || $ct == 2) ? 1 : 0;
        my $cancel_emitted = 0;   # emit the cancel command at most once.

        my $start_future  = Temporalio::Workflow::Future->new;
        my $result_future = Temporalio::Workflow::Future->new;

        require Temporalio::Workflow::NexusOperationHandle;
        my $handle = Temporalio::Workflow::NexusOperationHandle->new(
            nexus_operation_seq => $seq,
            endpoint            => $endpoint,
            service             => $service,
            operation           => $operation,
            start_future        => $start_future,
            result_future       => $result_future,
            # cancel hook: emit RequestCancelNexusOperation (unless abandon), then
            # either fail the pending awaits now (abandon / try_cancel) or stay
            # parked until the cancelled resolve (wait_* types). Under the wait_*
            # types the seq STAYS mapped so the later ResolveNexusOperation
            # {cancelled} settles it.
            on_cancel => sub ($h) {
                return unless exists $pending_nexus_operations{$seq};
                if (!$is_abandon && !$cancel_emitted) {
                    push @commands,
                        Temporalio::Workflow::Commands::request_cancel_nexus_operation(
                            $seq);
                    $cancel_emitted = 1;
                }
                return unless $report_now;
                delete $pending_nexus_operations{$seq};
                for my $f ($start_future, $result_future) {
                    next if $f->is_ready;
                    $f->fail(Temporalio::Exception::Cancelled->new(
                        message => 'Nexus operation cancelled',
                    ));
                }
            },
        );

        $pending_nexus_operations{$seq} = $handle;

        # Pre-scheduled cancel (spec section 26.3): if the run is already
        # cancel-requested, raise Cancelled on the start await immediately.
        # $handle->cancel alone honours the wait_* cancellation types and would
        # stay parked, so force-report exactly as the whole-workflow cancel
        # sweep does: emit the cancel command (unless abandon), de-register,
        # and fail the pending awaits with Cancelled. Nexus is the ONLY arm
        # with a per-call pre-scheduled check (finding R3, equal to L31b: an
        # earlier version of this comment claimed an activity/child mirror
        # that was never built). Activities, timers, and children get their
        # cancellation from the _apply_cancel_workflow fallback instead, which
        # sweeps every pending map from a pre-sweep snapshot (findings
        # R4/R4b/R4c, spec R8-R10); anything scheduled AFTER the cancel
        # arrived is post-cancel cleanup work and deliberately runs to
        # completion. That snapshot is also why this arm must report on its
        # own: pre-R8 it relied on the nexus sweep re-reading the map keys
        # after the body had resumed, and the snapshot fix closed that path.
        if ($cancel_requested) {
            $handle->cancel;   # emit the cancel command (honours abandon).
            delete $pending_nexus_operations{$seq};
            for my $f ($start_future, $result_future) {
                next if $f->is_ready;
                $f->fail(Temporalio::Exception::Cancelled->new(
                    message => 'Nexus operation cancelled (workflow cancelled)',
                ));
            }
        }

        return $start_future;
    }

    # continue_as_new(%opts): route the continue-as-new request through the
    # workflow-outbound interceptor chain (spec R71; MUST-match sdk-python
    # worker/_interceptor.py:431-433 continue_as_new, whose chain root raises
    # _ContinueAsNewError). NEVER returns: the chain root dies with the
    # Temporalio::Workflow::ContinueAsNew control signal, which unwinds the
    # :Run coroutine and is caught by the outcome decision table. %opts are
    # the Temporalio::Workflow::continue_as_new kwargs (workflow, args,
    # task_queue, retry_policy, memo, search_attributes, headers,
    # run_timeout / task_timeout, versioning_intent); the input's Python-parity
    # primary field is `workflow` (worker/_interceptor.py:160-177
    # ContinueAsNewInput), args/headers are writable, the rest rides in kwargs.
    method continue_as_new (%opts) {
        my $input =
            Temporalio::Worker::Interceptor::Input::ContinueAsNew->new(
                workflow => delete $opts{workflow},
                args     => delete($opts{args}) // [],
                headers  => { %{ delete($opts{headers}) // {} } },
                kwargs   => { %opts },
                _root    => sub { $self->_root_continue_as_new($_[0]) },
            );
        $workflow_outbound->continue_as_new($input);
        # The root die always unwinds; reaching here means an interceptor
        # swallowed the control signal, which would complete the run normally.
        die 'Temporalio::Workflow::Runner: continue_as_new returned; a '
          . 'workflow-outbound interceptor must not swallow the '
          . 'ContinueAsNew control signal';
    }

    # The chain root: die with the ContinueAsNew control signal built from the
    # (possibly interceptor-mutated) input (spec R71); only caller-supplied
    # options are carried, so the command builder's only-set-fields contract
    # holds (empty args/headers are dropped here).
    method _root_continue_as_new ($input) {
        my $workflow = $input->get('workflow');
        my $args     = $input->args // [];
        my $headers  = $input->headers // {};
        die Temporalio::Workflow::ContinueAsNew->new(
            (defined $workflow ? (workflow => $workflow) : ()),
            (@$args             ? (args => $args)        : ()),
            (%$headers          ? (headers => $headers)  : ()),
            %{ $input->get('kwargs') },
        );
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

    # start_timer($seconds, %opts) -> a Temporalio::Workflow::Future resolved
    # when the matching FireTimer job arrives. Allocates the next TIMER seq (a
    # seq space separate from activities — sdk-python _next_seq("timer") /
    # sdk-ruby @timer_counter), builds the StartTimer command, buffers it, and
    # registers the pending Future. Cancelling the returned Future emits a
    # CancelTimer command (same seq) and resolves the Future as Temporalio::
    # Exception::Cancelled (MUST-match sdk-ruby _apply_cancel_command /
    # CanceledError). %opts: summary, a single-line fixed summary placed on the
    # command's user_metadata.summary Payload.
    method start_timer ($seconds, %opts) {
        $self->_assert_writable('start_timer/sleep');
        my $seq = ++$timer_seq_counter;   # timer seq space, from 1.

        # summary -> the WorkflowCommand user_metadata.summary Payload,
        # converted up front so a converter error surfaces at the call site
        # (spec R78 / in-workflow finding 2; MUST-match sdk-python
        # workflow/_context.py:878,894, which carries sleep's summary and
        # wait_condition's timeout_summary to the timer command). The activity,
        # LA, and nexus arms already follow this convention.
        my $summary = defined $opts{summary}
            ? $payload_converter->to_payload($opts{summary}) : undef;

        push @commands, Temporalio::Workflow::Commands::start_timer({
            seq                   => $seq,
            start_to_fire_timeout => _duration($seconds),
        }, $summary);

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
    # timeout_summary optionally labels the backing timeout timer: it rides to
    # the StartTimer command's user_metadata.summary (spec R78 / in-workflow
    # finding 2; MUST-match sdk-python workflow/_context.py:894).
    method wait_condition ($predicate, %opts) {
        # The wait_condition awaitable is a _ConditionFuture whose ->cancel FAILS
        # the future with a throwable Temporalio::Exception::Cancelled (#5, #8) —
        # NOT Future's native cancelled state. A natively-cancelled CPAN Future
        # would make the awaiting :Run (or in-flight :Update/:Signal handler)
        # throw a bare "was cancelled" string, which escapes :Run as a plain die
        # and fails the workflow task forever instead of routing to
        # CancelWorkflowExecution. This mirrors _TimerFuture / _ActivityFuture and
        # the references (sdk-ruby fiber.raise(CanceledError); sdk-python
        # task-cancel -> CancelledError), where the cancellation is an EXCEPTION
        # raised into the parked frame. _apply_cancel_workflow drives the cancel.
        my $timer;
        my $future = Temporalio::Workflow::Runner::_ConditionFuture->_new_condition(
            on_cancel => sub {
                # Drop the (now soon-to-be-ready) wait timer if one was racing —
                # emitting CancelTimer once. A no-op when the timer already fired
                # or was cancelled by the pending-timer sweep.
                $timer->cancel if defined $timer && !$timer->is_ready;
            },
        );

        if (defined $opts{timeout}) {
            # timeout_summary -> the backing timer's user_metadata.summary
            # (start_timer converts it and skips an undef).
            $timer = $self->start_timer($opts{timeout},
                summary => $opts{timeout_summary});
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
            # Iterate a SNAPSHOT of the pending entries, not @conditions itself
            # (#3, #4): a satisfied predicate's continuation runs synchronously
            # inside $future->done below and may register a FRESH wait_condition
            # (pushing onto @conditions) or even re-enter _check_conditions. A
            # snapshot keeps that mid-pass mutation from corrupting the loop
            # cursor, so the iteration is deterministic regardless of what the
            # continuation does to the live list. (wait_condition itself
            # re-enters _check_conditions, which reassigns @conditions; aliasing
            # a foreach over that live array across the reassignment is the
            # re-entrancy hazard this snapshot closes.)
            my @snapshot = @conditions;
            for my $cond (@snapshot) {
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
            }
            # Rebuild the pending list by DROPPING resolved entries from the
            # LIVE @conditions, NOT by replacing it with a list built from the
            # snapshot (the old `@conditions = @still`). A wait_condition the
            # continuation re-registered DURING this pass (#3: the
            # batch-sliding-window re-park; #4: the updatable-timer re-arm) lives
            # in @conditions but not in any snapshot-derived list; replacing
            # wholesale silently dropped it, wedging the body Running with no
            # pending tasks and no terminal command. Filtering the live list
            # keeps every still-pending entry, including those added mid-pass,
            # and the outer while-loop then re-evaluates them on the next pass.
            @conditions = grep { !$_->{future}->is_ready } @conditions;
        }
        return;
    }

    # --- activation processing (spec section 10.3) ---------------------------

    # process_activation($activation) -> the WorkflowActivationCompletion proto.
    method process_activation ($activation) {
        # Steps 1-2: activation context. (Step 3 job ordering and the full
        # job set are handled below: the jobs are ordered into the de-facto
        # Temporal sets and applied via _apply_job.)
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
        # buffer once the instance exists, BEFORE kicking off the :Run body, so
        # handler side effects are visible to the main routine's first statement
        # (T-wf-3 visibility; spec R26 signals-before-main).
        dynamically $Temporalio::Workflow::Runner::CURRENT = $self;
        my $set_index = -1;
        try {
            for my $job_set ($self->_ordered_job_sets($activation)) {
                $set_index++;
                next unless @$job_set;
                $self->_apply_job($_) for @$job_set;
                # Re-check wait_condition predicates only after the signal set
                # (1) and the non-query set (2) — NOT after patches (0) or
                # queries (3). A query activation (incl. a standalone
                # "legacy_query") must not advance the workflow: resuming a
                # parked :Run there would emit a CompleteWorkflow alongside the
                # QueryResult, which core rejects ("legacy query response along
                # with other commands"). MUST-match sdk-python activate():
                # _run_once(check_conditions=index==1 or 2).
                $self->_pump(check_conditions => ($set_index == 1 || $set_index == 2));
            }

            # Steps 6-7: drain the command buffer into a completion proto.
            return $self->_build_completion;
        }
        catch ($err) {
            # THE die-to-failed-completion funnel (spec R11, finding R5): any
            # die that escapes job application, the pump, or the completion
            # builder — e.g. a :Query handler returning a pending future, whose
            # `->result` read croaks — maps to a failed workflow-TASK completion
            # (the server retries the task), the same route the recorded
            # $current_activation_error takes. Pre-fix the die escaped
            # process_activation, the poll loop warned-and-swallowed it, and
            # the workflow task was never completed: the workflow wedged until
            # timeout, forever on each retry. The completion contract with core
            # is one completion per activation, on every path.
            return $self->_task_failed_completion($err);
        }
    }

    # evict (spec section 10.3 RemoveFromCache): tear the runner down. Cancel
    # every pending activity/timer Future and the main run Future so no dangling
    # continuation survives the run's removal from the dispatcher cache. The
    # dispatcher drops the run_id -> runner mapping; no workflow code runs and an
    # empty successful completion is returned (the §8.3 eviction fast path).
    # MUST-match sdk-python _handle_cache_eviction (deletes the run from
    # _running_workflows after cancelling its tasks).
    method evict () {
        # Iterate COPIED snapshots of the pending tables, never the aliased
        # `values` lists (finding L6 / spec R16). Cancel continuations run
        # synchronously and may de-register ANY pending entry: each future's
        # on_cancel deletes its own hash slot, and a Future->wait_any
        # loser-cancel chains that delete onto a SIBLING (cancelling the
        # activity fails it Cancelled, wait_any then cancels the losing timer,
        # whose on_cancel deletes the not-yet-visited $pending_timers slot).
        # A foreach over `values` aliases the hash slots, so that sibling
        # delete freed an alias this loop still held and evict croaked before
        # sending the eviction completion (the step-45 probe_l6_freed_iteration
        # croak, at the pre-fix trace Runner.pm:1532-1538; own-entry deletion
        # alone was survivable per probe_l6_self_delete). The whole-workflow
        # cancel sweeps learned the same lesson and snapshot `keys` first
        # (pre-fix trace :2199, :2212, in _apply_cancel_workflow below). The
        # array copies hold their own references, so continuations may delete
        # any entry and eviction always completes.
        # Activities (regular AND local) are FORCE-cancelled: eviction ignores
        # the cancellation type (spec R52 / finding L8). The wait-honouring
        # ->cancel parked a wait_cancellation_completed future forever — the
        # cancel command was emitted but the future stayed pending, so the
        # frame parked on the await was abandoned without ever unwinding.
        # _force_cancel always fails the future Cancelled: the awaiting frame
        # resumes synchronously (its catch/cleanup runs) and the run is always
        # releasable. Same snapshot-copy rule as below.
        my @pending_activity_futures = values %pending_activities;
        for my $future (@pending_activity_futures) {
            $future->_force_cancel unless $future->is_ready;
        }
        my @pending_futures = (
            values %pending_timers,
            values %in_progress_handlers, values %pending_external_signals,
            values %pending_external_cancels,
            map { $_->{future} } @conditions,
        );
        for my $future (@pending_futures) {
            $future->cancel unless $future->is_ready;
        }
        # Child handles own a start AND a result Future; cancel both. Snapshot
        # here too: a child handle's cancel de-registers its seq (the reason
        # _apply_cancel_workflow snapshots keys), and wait_any can chain a
        # sibling handle's de-register exactly as above.
        my @child_handles = values %pending_child_workflows;
        for my $handle (@child_handles) {
            for my $f ($handle->start_future, $handle->result_future) {
                $f->cancel unless $f->is_ready;
            }
        }
        # Nexus handles likewise own a start AND a result Future.
        my @nexus_handles = values %pending_nexus_operations;
        for my $handle (@nexus_handles) {
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
        %pending_nexus_operations       = ();
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
        if ($variant eq 'resolve_nexus_operation_start') {
            return $self->_apply_resolve_nexus_operation_start(
                $job->resolve_nexus_operation_start);
        }
        if ($variant eq 'resolve_nexus_operation') {
            return $self->_apply_resolve_nexus_operation(
                $job->resolve_nexus_operation);
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
        # RemoveFromCache never reaches the runner (the dispatcher's eviction
        # fast path consumes it); any other variant is unknown to this SDK.
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

        # Seed the init-derived static info() fields (spec R36 / finding A5).
        # Defaults are the proto3 scalar defaults, matching Python's direct
        # init.workflow_id / init.attempt reads (a real activation from core
        # always carries both; attempt starts at 1).
        %init_info = (
            workflow_id => $init->workflow_id // '',
            attempt     => $init->attempt     // 0,
        );

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

        # Build the workflow-inbound AND workflow-outbound interceptor chains
        # now the instance exists (spec R71; #10 for the inbound half). Both
        # are cached for the run, so signals/queries/updates and every
        # outbound operation on later activations route through them too.
        ($workflow_inbound, $workflow_outbound) =
            $self->_build_interceptor_chains;
        # SIGNALS-BEFORE-MAIN (spec R26, finding R12): drain the init
        # activation's buffered signals (then updates) BEFORE kicking off the
        # :Run body, so handler side effects are visible to the main routine's
        # FIRST statement. That is signal-with-start parity with sdk-python,
        # where activate() applies the signal_workflow + do_update set and
        # pumps the loop before initialize_workflow starts the main routine
        # (_workflow_instance.py:438-471), and _apply_signal_workflow
        # (:1057-1065) dispatches registered handlers immediately. The inbound
        # interceptor chain is already built above, so drained handlers route
        # through it exactly as post-start ones do. Pre-fix the body was kicked
        # off first and the drain ran after, so the prologue saw pre-signal
        # state.
        $self->_drain_buffered_signals;
        # Drain any updates buffered before the instance existed (spec section
        # 19.2): a DoUpdate ordered before InitializeWorkflow in the init
        # activation is dispatched here, after the buffered signals and, like
        # them, before the main routine starts (Python set 1).
        $self->_drain_buffered_updates;

        # Thread the start headers off the InitializeWorkflow job into the
        # inbound input the same way the outbound paths (schedule_activity et
        # al., ~L497) carry their `Str => Payload` header maps: the now-invoked
        # inbound hook (and context propagation built on it) reads the REAL
        # start headers here instead of an empty map (#10 C-ICEPT-HEADERS — the
        # input previously passed only type/args/_root, so the forwarded header
        # was empty and downstream activities saw request_id=(none)).
        my $start_headers = $init->headers // {};
        my $execute_input =
            Temporalio::Worker::Interceptor::Input::ExecuteWorkflow->new(
                type    => $workflow_class,
                args    => [@args],
                headers => { %$start_headers },
                _root   => sub ($in) { $instance->$run_ref(@{ $in->args }) },
            );
        $main_run_future = $workflow_inbound->execute_workflow($execute_input);
        return;
    }

    # Build the workflow interceptor chains (spec R71, parity finding 1;
    # MUST-match sdk-python _workflow_instance.py:392-398 and
    # worker/_interceptor.py:416-481): fold the combined interceptor list over
    # a root inbound (first-listed outermost; build_workflow_inbound iterates
    # in reverse), then call inbound->init(root outbound). Each interceptor
    # inbound may WRAP the outbound it receives before delegating init down
    # the chain, so the outbound that reaches the ROOT inbound is the finished
    # outbound chain (last-listed wrapper outermost, Python's exact init
    # semantics); the root's on_init hands it back here, the Perl form of
    # _WorkflowInboundImpl.init storing self._outbound. The eight outbound
    # operations (execute_activity, execute_local_activity,
    # start_child_workflow, signal_child_workflow, signal_external_workflow,
    # continue_as_new, start_nexus_operation, info) route through it. The
    # execute_workflow root reads the kicked-off body from the input's `_root`
    # coderef (the client-outbound _RootOutbound convention), as does every
    # outbound root method.
    method _build_interceptor_chains {
        # The init-capture mechanics (and the loud die when an inbound init
        # fails to delegate to the chain root) live in the shared
        # build_chains helper, which the ActivityDispatcher's R72 chain
        # build uses too.
        return Temporalio::Worker::Interceptor::build_chains(
            $interceptors,
            \&Temporalio::Worker::Interceptor::build_workflow_inbound,
            'Temporalio::Worker::_RootWorkflowInbound',
            'Temporalio::Worker::_RootWorkflowOutbound',
            'workflow');
    }

    # ResolveActivity { seq, result } — resolve the pending activity Future for
    # this seq (spec section 10.3; MUST-match sdk-python _apply_resolve_activity).
    # ActivityResolution.status is a oneof: completed -> ->done(decoded result);
    # failed/cancelled -> ->fail(exception mapped from the Failure proto). The
    # awaiting workflow continuation runs synchronously at resolve time
    # (Future::AsyncAwait on_ready), so progress is observed in the pump.
    method _apply_resolve_activity ($job) {
        my $seq    = $job->seq;
        # The resolution retires the seq; drop the at-most-once cancel
        # sent-flag with it (spec R53) so the run-scoped map does not grow.
        delete $activity_cancel_requested{$seq};
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

    # ResolveNexusOperationStart { seq, operation_token|started_sync|failed } —
    # the first stage of the nexus two-stage resolution (spec section 26.3). Look
    # up by seq (unknown -> non-determinism via _record_nondeterminism, matching
    # the codebase's child-workflow start handling):
    #   operation_token -> ASYNC start: store the token, ->done the start Future,
    #     do NOT pop (the ResolveNexusOperation result job is still to come).
    #   started_sync    -> SYNC start: token undef, ->done the start Future, do
    #     NOT pop (the result job is in the SAME activation, per the proto).
    #   failed          -> the start failed: POP the seq and ->fail the start
    #     Future with the mapped failure (NO result job follows).
    # MUST-match sdk-python _apply_resolve_nexus_operation_start.
    method _apply_resolve_nexus_operation_start ($job) {
        my $seq    = $job->seq;
        my $handle = $pending_nexus_operations{$seq};
        unless (defined $handle) {
            $self->_record_nondeterminism(
                "ResolveNexusOperationStart for unknown seq $seq (no pending "
                . "nexus operation) — non-determinism: the workflow never "
                . "scheduled this operation");
            return;
        }

        my $status = $job->which_status // '';
        if ($status eq 'operation_token') {
            # Async operation started: keep the seq mapped (result job follows).
            $handle->_resolve_started($job->operation_token);
        }
        elsif ($status eq 'started_sync') {
            # Sync operation: token undef; the result job is in this activation.
            $handle->_resolve_started(undef);
        }
        elsif ($status eq 'failed') {
            # Start failed: no result job follows. Pop and fail the start await
            # with a NexusOperation exception (spec section 26.4). The start
            # `failed` Failure may itself be a nexus_operation_execution_failure
            # (then from_failure yields a NexusOperation directly) or a bare inner
            # failure (then wrap it, carrying the handle's endpoint/service/op).
            delete $pending_nexus_operations{$seq};
            my $failure = $job->failed;
            my $mapped = defined $failure
                ? $failure_converter->from_failure($failure, $payload_converter)
                : undef;
            my $exc = (defined $mapped
                    && $mapped->isa('Temporalio::Exception::NexusOperation'))
                ? $mapped
                : Temporalio::Exception::NexusOperation->new(
                      message   => 'Nexus operation failed to start',
                      endpoint  => $handle->endpoint,
                      service   => $handle->service,
                      operation => $handle->operation,
                      (defined $mapped ? (cause => $mapped) : ()),
                  );
            $handle->start_future->fail($exc)
                unless $handle->start_future->is_ready;
        }
        else {
            die "Temporalio::Workflow::Runner: ResolveNexusOperationStart seq "
              . "$seq had no recognized status (got '$status')";
        }
        return;
    }

    # ResolveNexusOperation { seq, result } — the second (terminal) stage (spec
    # section 26.3). Look up by seq (unknown -> non-determinism per spec section
    # 26.4 / T-nexus-9; note sdk-python tolerates an unknown seq here, but the
    # spec mandates non-determinism — spec wins). Read the NexusOperationResult
    # oneof: `completed` -> ->done with the converted result; `failed` /
    # `cancelled` / `timed_out` -> ->fail with the mapped failure. The wire
    # failure for a nexus resolve is itself a nexus_operation_execution_failure
    # whose cause is the inner (Application / Timeout / Cancelled), so
    # from_failure yields a Temporalio::Exception::NexusOperation with the mapped
    # cause (spec section 26.4). Pop the seq.
    method _apply_resolve_nexus_operation ($job) {
        my $seq    = $job->seq;
        my $handle = delete $pending_nexus_operations{$seq};
        unless (defined $handle) {
            $self->_record_nondeterminism(
                "ResolveNexusOperation for unknown seq $seq (no pending nexus "
                . "operation) — non-determinism: the workflow never scheduled "
                . "this operation");
            return;
        }

        my $future = $handle->result_future;
        return if $future->is_ready;   # already cancelled via the handle.

        my $resolution = $job->result;
        my $status     = defined $resolution ? $resolution->which_status : '';
        $status //= '';

        if ($status eq 'completed') {
            my $payload = $resolution->completed;
            my $value   = defined $payload
                ? $payload_converter->from_payload($payload)
                : undef;
            $future->done($value);
        }
        elsif ($status eq 'failed' || $status eq 'cancelled'
            || $status eq 'timed_out')
        {
            # The wire Failure for a nexus resolve is itself a
            # nexus_operation_execution_failure whose cause is the mapped inner
            # (Application for `failed`, Cancelled for `cancelled`, Timeout for
            # `timed_out`), so from_failure yields a
            # Temporalio::Exception::NexusOperation with the mapped cause directly
            # (spec section 26.4; MUST-match sdk-python, which calls from_failure
            # on the arm). If core ever sends a bare inner failure (no nexus
            # wrapper), wrap it in a NexusOperation carrying the handle's
            # endpoint/service/operation so the surface stays consistent.
            my $failure = $resolution->$status;
            my $mapped = defined $failure
                ? $failure_converter->from_failure($failure, $payload_converter)
                : undef;
            my $exc = (defined $mapped
                    && $mapped->isa('Temporalio::Exception::NexusOperation'))
                ? $mapped
                : Temporalio::Exception::NexusOperation->new(
                      message         => 'Nexus operation failed',
                      endpoint        => $handle->endpoint,
                      service         => $handle->service,
                      operation       => $handle->operation,
                      operation_token => $handle->operation_token,
                      (defined $mapped ? (cause => $mapped) : ()),
                  );
            $future->fail($exc);
        }
        else {
            die "Temporalio::Workflow::Runner: ResolveNexusOperation seq $seq "
              . "had no recognized result status (got '$status')";
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
        # and its handle emits the per-op cancel command). Every pending map is
        # swept from the ONE list below (findings R4/R4b/R4c) so a map cannot be
        # missed the way %pending_external_signals / %pending_external_cancels
        # were (R4c). Each list entry pairs a SNAPSHOT of the map's current
        # entries with that map's cancel action, and every snapshot is taken
        # when the list is built — before any sweep runs. That ordering is the
        # deliver-cancellation-then-continue mechanism (R4 / spec R8, Python
        # parity): failing a pending Future resumes the awaiting frame
        # synchronously, and a body that catches the Cancelled may immediately
        # schedule NEW post-cancel cleanup work into any of these maps. Only
        # entries pending at the moment the cancel arrived are swept; the
        # post-cancel work survives every remaining sweep (and the guarded
        # main-run-future fallback below) and runs to completion.
        my @sweeps = (
            # Backing-off local activities (spec section 21.2 / T-local-13) are
            # NOT in %pending_activities — their state is stashed on a backoff
            # timer while parked. Cancel each pending backoff timer
            # (CancelTimer, dropping its re-schedule) and fail the LA's outer
            # future Cancelled. Listed before the generic timer sweep so the
            # re-schedule on_done never fires (the timer sweep then sees the
            # backoff timer already ready and skips it).
            [ [keys %local_activity_backoff_timers] => sub ($tseq) {
                my $info  = delete $local_activity_backoff_timers{$tseq};
                my $timer = $pending_timers{$tseq};
                $timer->cancel if defined $timer && !$timer->is_ready;
                my $la_future = $info->{state}{future};
                if (defined $la_future && !$la_future->is_ready) {
                    $la_future->fail(Temporalio::Exception::Cancelled->new(
                        message => 'Local activity cancelled (workflow cancelled)',
                    ));
                }
            } ],
            # FORCE-cancel every pending activity Future (regular AND local):
            # that emits the arm's RequestCancel command (so core forwards the
            # cancel to the running activity — unless the activity is
            # ABANDON-typed, which never asks core to cancel) and then fails
            # the Future with Cancelled, so the awaiting body raises a proper
            # Temporal cancellation (a natively-cancelled Future would surface
            # a bare "was cancelled" string, losing the exception identity).
            # The primary-task cancel always raises — it does not honour
            # wait_cancellation_completed on either arm (the shared _force
            # convention, spec R12+R52) — so both future classes route through
            # _force_cancel here, never the wait-honouring ->cancel.
            # Continuations run synchronously at resolve time, so the body
            # observes the cancellation before _pump/_build_completion.
            [ [keys %pending_activities] => sub ($seq) {
                my $future = $pending_activities{$seq};
                return if !defined $future || $future->is_ready;
                $future->_force_cancel;
            } ],
            # Timer Futures carry the analogous override (emit CancelTimer +
            # fail Cancelled).
            [ [keys %pending_timers] => sub ($seq) {
                my $future = $pending_timers{$seq};
                $future->cancel if defined $future && !$future->is_ready;
            } ],
            # Child workflows join the cancel chain (spec section 18.2 /
            # T-child-11): each pending child handle is cancelled (emitting
            # CancelChildWorkflowExecution unless abandon) AND its pending
            # start/result awaits are failed with Cancelled so the awaiting
            # body observes the cancellation in this activation (mirrors
            # T-act-9 for activities). Unlike an explicit $handle->cancel —
            # which honours the wait_* cancellation_type and may stay parked —
            # the primary-task cancel always raises at the await. The handle's
            # cancel de-registers the seq, hence the snapshot.
            [ [keys %pending_child_workflows] => sub ($seq) {
                my $handle = $pending_child_workflows{$seq} // return;
                $handle->cancel;   # emit the cancel command (honours abandon).
                delete $pending_child_workflows{$seq};
                for my $f ($handle->start_future, $handle->result_future) {
                    next if $f->is_ready;
                    $f->fail(Temporalio::Exception::Cancelled->new(
                        message => 'Child workflow cancelled (workflow cancelled)',
                    ));
                }
            } ],
            # Nexus operations join the cancel chain (spec section 26.3)
            # exactly as child workflows above: cancel the handle (emitting
            # RequestCancelNexusOperation unless abandon), then fail its
            # pending start/result awaits with Cancelled.
            [ [keys %pending_nexus_operations] => sub ($seq) {
                my $handle = $pending_nexus_operations{$seq} // return;
                $handle->cancel;   # emit the cancel command (honours abandon).
                delete $pending_nexus_operations{$seq};
                for my $f ($handle->start_future, $handle->result_future) {
                    next if $f->is_ready;
                    $f->fail(Temporalio::Exception::Cancelled->new(
                        message => 'Nexus operation cancelled (workflow cancelled)',
                    ));
                }
            } ],
            # External-signal and external-cancel acknowledgement Futures join
            # the cancel chain (finding R4c / spec R10): a body parked on
            # signal_external_workflow_execution or on a
            # request_cancel_external_workflow_execution acknowledgement must
            # observe Cancelled exactly as the activity/timer/child maps
            # deliver it. Fail (never natively cancel) each pending Future so
            # the awaiting frame raises a throwable
            # Temporalio::Exception::Cancelled; the seq stays mapped so a late
            # Resolve* from core is dropped cleanly by the is_ready guard (the
            # spec section 20.2 in-flight-cancel convention).
            [ [keys %pending_external_signals] => sub ($seq) {
                my $future = $pending_external_signals{$seq};
                return if !defined $future || $future->is_ready;
                $future->fail(Temporalio::Exception::Cancelled->new(
                    message => 'External signal cancelled (workflow cancelled)',
                ));
            } ],
            [ [keys %pending_external_cancels] => sub ($seq) {
                my $future = $pending_external_cancels{$seq};
                return if !defined $future || $future->is_ready;
                $future->fail(Temporalio::Exception::Cancelled->new(
                    message => 'External cancel request cancelled (workflow cancelled)',
                ));
            } ],
            # wait_condition awaitables join the cancel chain (#5, #8). The
            # :Run body parked on a never-true wait_condition — and any
            # in-flight :Update / :Signal handler parked on its own
            # wait_condition — must raise a throwable
            # Temporalio::Exception::Cancelled, NOT a native Future cancel.
            # Each entry's future is a _ConditionFuture whose ->cancel fails it
            # Cancelled (and drops any racing wait timer); the awaiting frame
            # then resumes synchronously and propagates Cancelled, so the :Run
            # body unwinds to CancelWorkflowExecution and a mid-update handler
            # settles cleanly rather than leaking a raw cancelled Future that
            # hangs the workflow task. The snapshot matters here too: a
            # satisfied/cancelled entry is dropped from @conditions by the next
            # _check_conditions pass, and the resuming continuation may mutate
            # @conditions. Swept BEFORE the main_run_future fallback so the
            # body has already unwound by the time the fallback runs (it then
            # no-ops).
            [ [map { $_->{future} } @conditions] => sub ($future) {
                return if !defined $future || $future->is_ready;
                $future->cancel;
            } ],
        );
        for my $sweep (@sweeps) {
            my ($entries, $action) = @$sweep;
            $action->($_) for @$entries;
        }
        # Fallback: cancel the main run Future in case the body parked on
        # something other than a tracked pending Future / wait_condition. A no-op
        # once the body already unwound (Cancelled) above. Guarded (finding R4 /
        # spec R8): every pre-cancel pending entry was just swept, so any LIVE
        # tracked Future remaining here is NEW post-cancel work scheduled by a
        # body (or handler) that caught the Cancelled — cancelling the main run
        # Future then would fail the run mid-await and the later resolution
        # would die "already failed and cannot be ->done". Cancellation was
        # delivered once at the awaited point; post-cancel cleanup work runs to
        # completion (Python parity).
        if (defined $main_run_future && !$main_run_future->is_ready
            && !$self->_live_pending_futures)
        {
            $main_run_future->cancel;
        }
        return;
    }

    # Every not-yet-ready Future in the tracked pending maps, enumerated from
    # ONE list so the _apply_cancel_workflow fallback guard cannot drift from
    # the sweep above (findings R4/R4b/R4c): activities (local activities
    # included, plus parked backoff state), timers, child-workflow and nexus
    # handles (start + result), external signals, external cancels, and
    # wait_condition entries.
    method _live_pending_futures {
        return grep { defined($_) && !$_->is_ready } (
            values %pending_activities,
            values %pending_timers,
            (map { $_->{state}{future} } values %local_activity_backoff_timers),
            (map { ($_->start_future, $_->result_future) }
                values %pending_child_workflows),
            (map { ($_->start_future, $_->result_future) }
                values %pending_nexus_operations),
            values %pending_external_signals,
            values %pending_external_cancels,
            (map { $_->{future} } @conditions),
        );
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
    # activation) is buffered and drained inside _apply_initialize, after the
    # instance is created and BEFORE the :Run body is kicked off (spec R26
    # signals-before-main). A signal whose name has no named handler and no dynamic
    # handler is buffered too (T-wf-3 QUEUEING), held in arrival order until a
    # matching handler appears (or indefinitely in this static model — it never
    # fails the workflow).
    method _apply_signal_workflow ($job) {
        my $name = $job->signal_name // '';

        # No instance yet: the handler can only run against the instance the
        # InitializeWorkflow job creates. Buffer for the post-init drain.
        if (!defined $instance) {
            push $buffered_signals{$name}->@*,
                [ $buffered_signal_arrival++, $job ];
            return;
        }

        my ($handler, $is_dynamic) = $self->_resolve_signal_handler($name);
        if (!defined $handler) {
            # No named or dynamic handler: buffer (a dynamic handler may be
            # registered later; sdk-python keeps these for a later-added handler).
            push $buffered_signals{$name}->@*,
                [ $buffered_signal_arrival++, $job ];
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

        # Route through the workflow-inbound chain so every inbound handle_signal
        # is invoked (outermost first) before the real handler (#10). The root
        # reads the real handler from the input's `_root` coderef.
        my $future = Future->call(sub {
            my $input =
                Temporalio::Worker::Interceptor::Input::HandleSignal->new(
                    signal => $name,
                    args   => [@args],
                    _root  => sub ($in) {
                        return $is_dynamic
                            ? $instance->$handler($name, @{ $in->args })
                            : $instance->$handler(@{ $in->args });
                    },
                );
            return Future->wrap($workflow_inbound->handle_signal($input));
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
    # Called by _apply_initialize after the instance is created and before the
    # :Run body is kicked off (spec R26 signals-before-main). Signals whose name
    # now resolves to a handler (named or dynamic) are dispatched in arrival
    # order and removed from the buffer; a signal with still no handler stays
    # buffered.
    method _drain_buffered_signals {
        return unless defined $instance;
        # Two passes: collect every entry whose name now resolves, then
        # dispatch sorted by arrival stamp. The buffer is keyed by name, so a
        # single name-order pass would scramble CROSS-name arrival order to
        # hash order; sdk-python applies init-activation signals in job order
        # (_workflow_instance.py activate() set 1), and R26 requires the same
        # arrival order here.
        my @ready;
        for my $name (keys %buffered_signals) {
            my ($handler, $is_dynamic) = $self->_resolve_signal_handler($name);
            next unless defined $handler;   # still no handler: keep buffered.
            my $entries = delete $buffered_signals{$name};
            push @ready, map { [ $_->[0], $handler, $is_dynamic, $_->[1] ] }
                @$entries;
        }
        for my $entry (sort { $a->[0] <=> $b->[0] } @ready) {
            my (undef, $handler, $is_dynamic, $job) = @$entry;
            $self->_dispatch_signal($handler, $is_dynamic, $job);
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

        # Route the handler through the workflow-inbound chain so every inbound
        # handle_update is invoked (outermost first) before the real handler
        # (#10). The root reads the real handler from the input's `_root` coderef.
        my $future = Future->call(sub {
            my $input =
                Temporalio::Worker::Interceptor::Input::HandleUpdate->new(
                    id     => $job->id // '',
                    update => $name,
                    args   => [@args],
                    _root  => sub ($in) {
                        return $is_dynamic
                            ? $instance->$handler($name, @{ $in->args })
                            : $instance->$handler(@{ $in->args });
                    },
                );
            return Future->wrap($workflow_inbound->handle_update($input));
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

    # durable_scheduler_disabled($code) — run $code with the durable scheduler
    # disabled (spec section 27.4). Raises $durable_suppress_depth for the
    # duration of the block via Syntax::Keyword::Dynamically so it unwinds even
    # across an await, then returns whatever $code returns (in the caller's
    # context). The OpenTelemetry tracing interceptor wraps span attach/extract
    # that touches a mutex or real wall-clock time in this so the work never
    # becomes part of the recorded history.
    method durable_scheduler_disabled ($code) {
        dynamically $durable_suppress_depth = $durable_suppress_depth + 1;
        return $code->();
    }

    # True while a durable_scheduler_disabled block is on the stack.
    method durable_scheduler_suppressed { return $durable_suppress_depth > 0 ? 1 : 0 }

    # Run a sync update validator under the read-only guard (spec section 19.2
    # step 3). Returns a hashref:
    #   { rejected => $failure_proto }  — the validator threw a normal failure
    #   { task_failure => 1 }           — the validator violated read-only
    #   {}                              — the validator passed (accept)
    # A read-only violation (the validator issued a command) is routed as a
    # workflow TASK failure via $current_activation_error.
    method _run_update_validator ($validator, $args) {
        my $commands_before = scalar @commands;
        my $future = Future->call(sub {
            dynamically $read_only_depth = $read_only_depth + 1;
            return Future->wrap($instance->$validator(@$args));
        });
        # Leak backstop (step R24 REFACTOR, finding R8; mirrors
        # _apply_query_workflow): commands buffered by an unguarded API inside
        # the read-only scope are stripped, and a validator that leaked without
        # dying is routed as the same task failure the guard would have raised.
        my $leaked = scalar(@commands) - $commands_before;
        if ($leaked > 0) {
            splice @commands, $commands_before, $leaked;
            if (!$future->failure) {
                $current_activation_error //= Temporalio::Exception::ReadOnly->new(
                    message => "Temporalio::Workflow::Runner: update validator "
                             . "emitted $leaked command(s) from a read-only "
                             . "context (unguarded API; add _assert_writable "
                             . "at its head)",
                );
                return { task_failure => 1 };
            }
        }
        if (my @failure = $future->failure) {
            my $err = $failure[0];
            # A read-only-context violation is a task failure, NOT a rejection
            # (typed check, step R24; formerly a fragile message-regex match).
            if (Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::ReadOnly'))
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

    # Classify a READY accepted-update handler Future into its settlement
    # (spec section 19.2 step 4 plus the R17 eviction rule). Returns exactly
    # one of:
    #   { completed    => $payload }        done: the encoded return value
    #   { rejected     => $failure_proto }  a Temporal-failure-type throw
    #   { task_failure => $err }            any other die (post-accept)
    #   { dropped      => 1 }               a CANCELLED handler future
    # The cancelled state MUST be discriminated before ->result (finding L7,
    # spec R17; step-45 probe probe_l7_cancelled_result.pl):
    #   state      is_ready  is_cancelled  ->failure  ->result
    #   done       1         0             ()         the value
    #   failed     1         0             ($err)     croaks with $err
    #   cancelled  1         1             ()         croaks "... was cancelled"
    # A cancelled future passes the ->failure check EMPTY and then ->result
    # croaks: the pre-fix _settle_update death that aborted evict() before it
    # could send the eviction completion. The only producer of a natively
    # cancelled handler future is evict()'s %in_progress_handlers sweep, and
    # the eviction contract is DROP: no UpdateResponse, no activation error,
    # matching sdk-python where the update task's teardown exception during
    # eviction is swallowed with no response (_workflow_instance.py
    # run_update, `except BaseException` under self._deleting). A task-cancel
    # OUTSIDE eviction is the rejected branch instead: the workflow cancel
    # chain throws Temporalio::Exception::Cancelled INTO the handler, so its
    # future arrives here FAILED (sdk-python parity: asyncio.CancelledError
    # becomes a Temporal CancelledError and rejects the update).
    method _update_settlement ($future) {
        return { dropped => 1 } if $future->is_cancelled;
        if (my @failure = $future->failure) {
            my $err = $failure[0];
            return $self->_is_workflow_failure_exception($err)
                ? { rejected =>
                        $failure_converter->to_failure($err, $payload_converter) }
                : { task_failure => $err };
        }
        return {
            completed => $payload_converter->to_payload(($future->result)[0]),
        };
    }

    # Settle an accepted update once its handler Future is ready (spec section
    # 19.2 step 4): a returned value -> UpdateResponse.completed; a Temporal
    # failure-type throw -> UpdateResponse.rejected (post-accept); any other die
    # -> a workflow TASK failure; a cancelled handler future (eviction, spec
    # R17) -> dropped, no response. Classification lives in _update_settlement
    # so the three-state contract is unit-testable directly.
    method _settle_update ($protocol_instance_id, $future) {
        my $settlement = $self->_update_settlement($future);
        return if $settlement->{dropped};
        if (exists $settlement->{task_failure}) {
            # A plain die post-acceptance is a workflow TASK failure.
            $current_activation_error //= $settlement->{task_failure};
            return;
        }
        if (exists $settlement->{rejected}) {
            push @commands, Temporalio::Workflow::Commands::update_response(
                $protocol_instance_id,
                rejected => $settlement->{rejected},
            );
            return;
        }
        push @commands, Temporalio::Workflow::Commands::update_response(
            $protocol_instance_id,
            completed => $settlement->{completed},
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

        # Route through the workflow-inbound chain so every inbound handle_query
        # is invoked (outermost first) before the real handler (#10). The root
        # reads the real handler from the input's `_root` coderef.
        #
        # The handler runs under the read-only guard (step R24, finding R8;
        # MUST-match sdk-python _apply_query_workflow's _as_read_only): any
        # command-emitting API dies with Temporalio::Exception::ReadOnly, which
        # the failed-query branch below converts into a RespondToQuery FAILED
        # response (Python catches it like any other query death). The
        # command-count snapshot backs the leak backstop after the scope exits.
        my $commands_before = scalar @commands;
        my $future = Future->call(sub {
            dynamically $read_only_depth = $read_only_depth + 1;
            my $input =
                Temporalio::Worker::Interceptor::Input::HandleQuery->new(
                    id    => $query_id,
                    query => $name,
                    args  => [@args],
                    _root => sub ($in) {
                        return $is_dynamic
                            ? $instance->$handler($name, @{ $in->args })
                            : $instance->$handler(@{ $in->args });
                    },
                );
            return Future->wrap($workflow_inbound->handle_query($input));
        });

        # Leak backstop (step R24 REFACTOR, finding R8): a command-emitting API
        # that forgot its head _assert_writable would have pushed commands from
        # inside the read-only scope without dying. Strip anything the handler
        # buffered so it never reaches the completion; if the handler otherwise
        # succeeded, fail the query with the same typed read-only error the
        # guard would have raised. New APIs therefore inherit the guard even
        # without a per-site assert.
        my $leaked = scalar(@commands) - $commands_before;
        if ($leaked > 0) {
            splice @commands, $commands_before, $leaked;
            if (!$future->failure) {
                push @commands, Temporalio::Workflow::Commands::respond_to_query(
                    $query_id,
                    failure => $failure_converter->to_failure(
                        Temporalio::Exception::ReadOnly->new(
                            message =>
                                "Temporalio::Workflow::Runner: query handler "
                              . "'$name' emitted $leaked command(s) from a "
                              . "read-only context (unguarded API; add "
                              . "_assert_writable at its head)",
                        ),
                        $payload_converter,
                    ),
                );
                return;
            }
        }

        if (my @failure = $future->failure) {
            # Dying handler -> query FAILED response (not a workflow/task fail).
            push @commands, Temporalio::Workflow::Commands::respond_to_query(
                $query_id,
                failure => $failure_converter->to_failure($failure[0], $payload_converter),
            );
            return;
        }

        # A handler that returns a PENDING future croaks on this read (a query
        # cannot wait); that die funnels to process_activation's catch (spec
        # R11, finding R5) and fails the workflow TASK — never an escaped die.
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

    # Assert the runner is NOT inside a read-only block (spec section 19.2 /
    # step R24, finding R8): neither an update validator nor a :Query handler
    # may issue commands or mutate workflow state. Called at the head of every
    # command-emitting runner method, BEFORE any side effect (seq allocation,
    # memoization, pending-map registration), so a violation leaves no stale
    # state behind. The guarded surface (the R24 table; MUST-match sdk-python
    # _assert_not_read_only call sites):
    #   schedule_activity, schedule_local_activity, start_child_workflow,
    #   _signal_child_workflow, _signal_external_workflow,
    #   _request_cancel_external_workflow, start_nexus_operation, start_timer,
    #   upsert_search_attributes, upsert_memo, patched.
    # A new command-emitting API MUST call this at its head; the command-leak
    # backstop in _apply_query_workflow / _run_update_validator catches one
    # that forgets. Inside a validator the throw is routed by _apply_do_update
    # to a workflow TASK failure (NOT an update rejection); inside a query it
    # becomes a failed query response. MUST-match sdk-python _as_read_only /
    # ReadOnlyContextError.
    method _assert_writable ($what) {
        return if $read_only_depth <= 0;
        die Temporalio::Exception::ReadOnly->new(
            message => "Temporalio::Workflow::Runner: while in a read-only "
                     . "context (query handler or update validator), action "
                     . "attempted: $what",
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
    # continuations. The main run Future is either already ready
    # (Future::AsyncAwait ran the body to completion synchronously) or
    # genuinely blocked on a pending workflow Future that a job in a
    # subsequent activation resolves. No IO::Async, no wall-clock.
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

    # Emit a workflow-terminal command (CompleteWorkflowExecution,
    # CancelWorkflowExecution, FailWorkflowExecution, or
    # ContinueAsNewWorkflowExecution) AT MOST ONCE across the run (B2 C-CANCEL-CMD,
    # bugs #6/#7). All three "this run is over" commands share this guard so a
    # post-terminal activation (core resolving an activity that a CancelWorkflow
    # (#6) or a wait_any loser-cancel (#7) left pending) does not re-push the
    # terminal command and produce the invalid [..., Cancel, Cancel] /
    # [..., Complete, Complete] sequence core rejects. Returns true when the
    # command was emitted, false when suppressed as a duplicate (so callers can
    # decide what else to buffer).
    method _emit_terminal_command ($cmd) {
        return 0 if $workflow_terminal_emitted;
        $workflow_terminal_emitted = 1;
        push @commands, $cmd;
        return 1;
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
            # A NATIVELY-cancelled run Future (finding R4b / spec R9): the
            # _apply_cancel_workflow fallback ->cancel'd a run Future whose
            # class has no Cancelled-failure override (the body's first await
            # was a plain Future, so the AWAIT_CLONEd run Future is one too).
            # Route it through the outcome table as a Cancelled failure so a
            # cancel-requested run maps to CancelWorkflowExecution — never to
            # the ->result croak the success branch below would raise.
            if ($main_run_future->is_cancelled) {
                return $self->_outcome_for_failure(
                    Temporalio::Exception::Cancelled->new(
                        message => 'Workflow cancelled',
                    ));
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
            # Guarded so a post-completion activation (e.g. core resolving a
            # wait_any loser activity, #7) never re-emits a second Complete.
            $self->_emit_terminal_command(
                Temporalio::Workflow::Commands::complete_workflow_execution($payload));
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
            $self->_emit_terminal_command(
                $self->_build_continue_as_new_command($err));
            return $self->_successful_completion;
        }

        # Cancelled after a CancelWorkflow job -> CancelWorkflowExecution (NOT a
        # FailWorkflowExecution). Gated on cancel_requested: a Cancelled with no
        # cancel request is a normal failure (sdk-python self._cancel_requested).
        if ($cancel_requested
            && Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Cancelled'))
        {
            # Guarded so a post-cancel activation (e.g. core resolving the
            # try_cancel activity, #6) never re-emits a second Cancel.
            $self->_emit_terminal_command(
                Temporalio::Workflow::Commands::cancel_workflow_execution());
            return $self->_successful_completion;
        }

        # A Nondeterminism escaping :Run (e.g. the determinism guard trapped a
        # time/entropy builtin in the body — spec §29.4) routes the SAME as a
        # recorded non-determinism: a workflow-TASK failure by default (the
        # server retries the task), a workflow failure only when
        # nondeterminism_as_workflow_fail is set. This is checked BEFORE the
        # generic Temporal-failure branch below, which would otherwise fail the
        # WORKFLOW because Nondeterminism isa Temporalio::Exception.
        if (Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Nondeterminism'))
        {
            return $nondeterminism_as_workflow_fail
                ? $self->_workflow_failed_completion($err)
                : $self->_task_failed_completion($err);
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

        # Pass-through Payloads, never re-encoded (#10 GAP B); shared contract in
        # Temporalio::Interceptor::Headers.
        if (my $headers = $opts{headers}) {
            if (%$headers) {
                $fields{headers} = Temporalio::Interceptor::Headers::to_payload_map(
                    $payload_converter, $headers);
            }
        }

        # search_attributes (field 8) and versioning_intent (field 10) were
        # dropped here despite the POD and the proto (spec R25, finding R11;
        # temporal/sdk/core/workflow_commands/workflow_commands.proto:212,217).
        # Both share the encoders used by the child-start builder; omitted
        # options keep the proto defaults.
        if (defined(my $sa = $opts{search_attributes})) {
            $fields{search_attributes} = _search_attributes_proto($sa);
        }
        if (defined(my $vi = $opts{versioning_intent})) {
            $fields{versioning_intent} = _versioning_intent_number($vi);
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
        my %success = (commands => \@out);
        # Per-workflow versioning behavior (spec §29.1): report the value from
        # the workflow class's :VersioningBehavior attribute in
        # WorkflowSuccess.versioning_behavior (field 7) — but ONLY in versioned
        # mode. Core rejects a versioning_behavior from a non-versioned worker
        # ("versioning behavior cannot be specified without deployment options
        # being set with versioned mode").
        if ($report_versioning_behavior
            && $workflow_class->can('_versioning_behavior_value')) {
            $success{versioning_behavior} =
                $workflow_class->_versioning_behavior_value;
        }
        return $completion_class->new({
            run_id     => $run_id,
            successful => \%success,
        });
    }

    # True when $cmd is a RespondToQuery command (its variant is the query
    # response oneof). The respond_to_query sub-message is a plain hashref
    # (proto sub-messages are not always blessed — lessons.md), so read it as a
    # hash, not via accessors.
    sub _is_query_response ($cmd) {
        return ($cmd->which_variant // '') eq 'respond_to_query';
    }

    # True when $cmd is a handler RESPONSE (a RespondToQuery or an
    # UpdateResponse) rather than a state-mutating workflow command. The
    # failure-completion partition (spec R13 / finding R9) keeps exactly these:
    # sdk-python (_set_workflow_failure, worker/_workflow_instance.py) never
    # clears its command buffer on workflow failure, so its query/update
    # responses always survive; this predicate is the Perl equivalent's
    # keep-list.
    sub _is_handler_response_command ($cmd) {
        my $variant = $cmd->which_variant // '';
        return $variant eq 'respond_to_query' || $variant eq 'update_response';
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

    # A workflow-FAILURE completion: FailWorkflowExecution carrying the
    # converted failure (T-wf-15b/c), plus any HANDLER RESPONSES buffered this
    # activation. The workflow execution itself fails (vs the task). Spec R13
    # (finding R9): query and update responses answered in the same activation
    # MUST survive the failure completion; only state-mutating workflow
    # commands (StartTimer, ScheduleActivity, ...) are dropped. Python ground
    # truth (../sdk-python temporalio/worker/_workflow_instance.py,
    # _set_workflow_failure): Python APPENDS fail_workflow_execution via
    # _add_command() to the already-accumulated successful.commands and clears
    # NOTHING — responses ride along. We additionally drop the mutating
    # commands, which the server never acts on past the fail. (An earlier
    # comment here claimed Python "adds only the fail command"; that was
    # false — finding R9.)
    method _workflow_failed_completion ($err) {
        # Partition, don't clear: keep the handler responses, drop the
        # state-mutating commands. Routed through the shared terminal-command
        # guard (#6/#7) so a post-terminal activation cannot re-emit a second
        # Fail; when already terminal, only the surviving responses remain.
        @commands = grep { _is_handler_response_command($_) } @commands;
        my $failure = $failure_converter->to_failure($err, $payload_converter);
        $self->_emit_terminal_command(
            Temporalio::Workflow::Commands::fail_workflow_execution($failure));
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

    # Nexus operation cancellation_type: spec string ->
    # NexusOperationCancellationType enum number (verified against
    # core/nexus/nexus.proto:84): wait_cancellation_completed=0, abandon=1,
    # try_cancel=2, wait_cancellation_requested=3. DEFAULT is
    # wait_cancellation_completed (0) per spec section 26.1 — here the proto ZERO,
    # unlike activities (try_cancel) and child workflows
    # (wait_cancellation_completed=2). A bad string dies at scheduling time.
    my %NEXUS_CANCELLATION_TYPE = (
        wait_cancellation_completed  => 0,
        abandon                      => 1,
        try_cancel                   => 2,
        wait_cancellation_requested  => 3,
    );
    sub _nexus_cancellation_type_number ($name) {
        return 0 unless defined $name;   # default: wait_cancellation_completed.
        return $NEXUS_CANCELLATION_TYPE{$name}
            // die "Temporalio::Workflow::Runner: unknown nexus operation "
                 . "cancellation_type '$name'";
    }

    # versioning_intent: spec string -> coresdk.common.VersioningIntent enum
    # number (verified against temporal/sdk/core/common/common.proto:20):
    # UNSPECIFIED=0, COMPATIBLE=1, DEFAULT=2. UNSPECIFIED is expressed by
    # OMITTING the option so the field keeps the proto default, matching
    # sdk-python, whose _apply_command only sets the field for a truthy intent
    # (_workflow_instance.py). A bad string dies at command-build time.
    my %VERSIONING_INTENT = (
        compatible => 1,
        default    => 2,
    );
    sub _versioning_intent_number ($name) {
        return $VERSIONING_INTENT{$name}
            // die "Temporalio::Workflow::Runner: unknown versioning_intent "
                 . "'$name'";
    }

    # Shared outbound search-attribute encoder (child start + continue-as-new,
    # spec R25): a typed collection exposing to_proto (the spec section 7.4
    # TypedSearchAttributes surface, mirroring the client start_workflow
    # request builder) is encoded once into a temporal.api.common.v1.
    # SearchAttributes message; an already-built proto passes through.
    sub _search_attributes_proto ($sa) {
        return Scalar::Util::blessed($sa) && $sa->can('to_proto')
            ? $sa->to_proto : $sa;
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

# A Workflow::Future for wait_condition (spec section 10.2) whose ->cancel maps
# to a Temporalio::Exception::Cancelled FAILURE (not Future's native cancelled
# state), mirroring _TimerFuture (#5, #8). The :Run body — and any in-flight
# :Update/:Signal handler — that parks on a never-true wait_condition is
# cancelled by _apply_cancel_workflow driving each entry's ->cancel; this raises
# a throwable Cancelled into the parked frame so the body unwinds to
# CancelWorkflowExecution instead of surfacing a bare "was cancelled" string that
# fails the workflow task forever. The on_cancel callback (supplied by
# wait_condition) drops any racing wait-timeout timer (CancelTimer). The entry is
# removed from @conditions by the next _check_conditions pass (which filters
# ready futures), so the callback need not touch the list.
package Temporalio::Workflow::Runner::_ConditionFuture {
    use v5.38;
    use warnings;

    use parent -norequire, 'Temporalio::Workflow::Future';
    use Temporalio::Exception::Cancelled ();

    # _new_condition(on_cancel => $cb) -> a pending wait_condition future. The
    # on_cancel callback runs exactly once, on the first ->cancel of a still-
    # pending condition.
    sub _new_condition ($class, %args) {
        my $self = $class->new;
        $self->{_cond_on_cancel} = $args{on_cancel};
        return $self;
    }

    # cancel: run the stored callback (drop the racing wait timer) then fail the
    # future with Cancelled so the awaiting frame raises a proper Temporal
    # cancellation. A no-op once the future is ready (already resolved/cancelled).
    sub cancel ($self) {
        return $self if $self->is_ready;
        if (my $cb = delete $self->{_cond_on_cancel}) {
            $cb->();
        }
        $self->fail(Temporalio::Exception::Cancelled->new(
            message => 'wait_condition cancelled',
        ));
        return $self;
    }
}

# A Workflow::Future for REGULAR activities whose ->cancel maps to a
# Temporalio::Exception::Cancelled FAILURE (not Future's native cancelled
# state), mirroring _TimerFuture. Like _LocalActivityFuture below, the cancel
# BEHAVIOUR is delegated to the runner (Runner::_on_activity_cancel) so it
# honours the cancellation type (spec R12 / finding R7): try_cancel/abandon
# resolve Cancelled now, wait_cancellation_completed parks until the delivered
# ResolveActivity resolves the future with the real outcome. Failing (never
# natively cancelling) preserves the Temporal exception identity at the await
# (a natively-cancelled CPAN Future would surface a bare "was cancelled"
# string). This is the activity end of the spec section 10.3 cancel chain
# (T-act-9).
package Temporalio::Workflow::Runner::_ActivityFuture {
    use v5.38;
    use warnings;

    use parent -norequire, 'Temporalio::Workflow::Future';
    use Scalar::Util ();
    use Temporalio::Exception::Cancelled ();

    # _new_activity(seq, runner, is_abandon, wait) -> a pending activity future.
    sub _new_activity ($class, %args) {
        my $self = $class->new;
        $self->{_act_seq}        = $args{seq};
        $self->{_act_runner}     = $args{runner};
        Scalar::Util::weaken($self->{_act_runner});
        $self->{_act_is_abandon} = $args{is_abandon} ? 1 : 0;
        $self->{_act_wait}       = $args{wait} ? 1 : 0;
        return $self;
    }

    # cancel: explicit handle cancellation. Delegate to the runner, which emits
    # RequestCancelActivity at most once (unless abandon) and returns whether to
    # resolve Cancelled now (try_cancel/abandon) or PARK
    # (wait_cancellation_completed — spec R12). A no-op once the future is
    # ready.
    sub cancel ($self) {
        return $self if $self->is_ready;
        my $runner = $self->{_act_runner} or return $self;
        my $resolve_now = $runner->_on_activity_cancel(
            $self->{_act_seq}, $self->{_act_is_abandon}, $self->{_act_wait});
        if ($resolve_now) {
            $self->fail(Temporalio::Exception::Cancelled->new(
                message => 'Activity cancelled',
            ));
        }
        return $self;
    }

    # _force_cancel: whole-workflow cancel / evict (the primary-task cancel
    # always raises, spec section 10.3 cancel chain; evict per spec R52 —
    # unlike an explicit ->cancel it does not honour
    # wait_cancellation_completed). Emits the cancel command at most once
    # (unless abandon) and fails the future Cancelled now.
    sub _force_cancel ($self) {
        return $self if $self->is_ready;
        my $runner = $self->{_act_runner};
        $runner->_force_activity_cancel(
            $self->{_act_seq}, $self->{_act_is_abandon}) if $runner;
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
(T-wf-15b/c). Query and update responses buffered in the same activation
survive alongside the fail command; only state-mutating commands are dropped
(spec R13, sdk-python parity).

=item *

Any other exception (a plain C<die>, a foreign class not listed) — the entire
completion is C<failed>: a workflow B<task> failure the server retries
(T-wf-15a).

=item *

A normal return — C<CompleteWorkflowExecution { result }> (T-wf-11).

=back

Query and update responses ride the same per-activation command buffer as
these outcome commands; C<RemoveFromCache> eviction is consumed by the
dispatcher's fast path and never reaches the runner.

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

=head2 create_nexus_client

Constructs a L<Temporalio::Workflow::NexusClient> bound to the given C<endpoint>
and C<service> (spec section 26.1). A synchronous, non-command constructor; the
client's C<start_operation>/C<execute_operation> emit the ScheduleNexusOperation
command through this runner.

=head2 start_nexus_operation

Emits a ScheduleNexusOperation command (oneof arm 21) on its own nexus seq space
and returns the start awaitable that resolves to a
L<Temporalio::Workflow::NexusOperationHandle> once the operation has started
(spec section 26.3). Converts the single argument, timeouts, cancellation_type,
and summary before buffering; registers the start and result Futures plus a
cancel hook honouring the C<NexusOperationCancellationType>.

=head2 info

Returns the workflow info hashref for the run: C<workflow_id>, C<run_id>,
C<workflow_type>, C<namespace>, C<task_queue>, C<attempt>, C<patches>,
C<search_attributes>, and C<memo> (spec R36; field names match Python's
C<workflow.info()>). A fresh copy per call, so callers cannot mutate the
runner's view through it. Routes through the workflow-outbound interceptor
chain (spec R71) once the run is initialized.

=head2 continue_as_new

Routes a continue-as-new request through the workflow-outbound interceptor
chain (spec R71); the chain root dies with the
L<Temporalio::Workflow::ContinueAsNew> control signal, so this method never
returns. C<%opts> mirror L<Temporalio::Workflow/continue_as_new> (C<workflow>,
C<args>, C<task_queue>, C<retry_policy>, C<memo>, C<search_attributes>,
C<headers>, C<run_timeout> / C<task_timeout>, C<versioning_intent>).

=head2 is_replaying

Returns true while the current activation is replaying history.

=head2 durable_scheduler_disabled

C<< $runner->durable_scheduler_disabled($code) >> runs C<$code> with the durable
scheduler disabled (spec section 27.4): while the block runs the runner neither
records commands on nor yields to the deterministic scheduler. Returns whatever
C<$code> returns. Used by the OpenTelemetry tracing interceptor for span
attach/extract that touches a mutex or real wall-clock time inside an
activation. See L<Temporalio::Workflow::Unsafe/durable_scheduler_disabled>.

=head2 durable_scheduler_suppressed

Returns true while a L</durable_scheduler_disabled> block is on the stack.

=head2 logger

Returns the run's replay-aware workflow logger.

=head2 memo

Returns the current in-workflow memo view as a name-to-converted-value
hashref, including upserted changes (spec R54; backs
C<Temporalio::Workflow::memo>). A fresh copy per call.

=head2 search_attributes

Returns the current in-workflow search-attribute view as a name-to-value
hashref, including upserted changes (spec R54; backs
C<Temporalio::Workflow::search_attributes>). A fresh copy per call.

=head2 patched

Implements the C<patched>/C<deprecate_patch> logic against history, emitting patch markers as needed.

=head2 process_activation

Applies one workflow activation (its jobs) against the workflow instance and returns the resulting completion (its buffered commands).
Never dies: any die that escapes job application or the completion builder is mapped to a workflow-B<task>-failure completion (spec R11, finding R5) — the completion contract with core is one completion per activation, on every path.

=head2 random

Returns the run's deterministic RNG seeded from the activation randomness seed.

=head2 run_id

Returns the run id of the workflow execution.

=head2 schedule_activity

Emits a ScheduleActivity command and returns the cancellable awaitable that resolves when the activity is resolved.
Options are validated first (spec R35): an unknown option key, or a call missing both C<start_to_close_timeout> and C<schedule_to_close_timeout>, raises L<Temporalio::Exception::Argument> before any command state changes.
A C<priority> option (a L<Temporalio::Common::Priority>) is carried to the command's C<priority> proto field and a C<summary> string to the command's C<user_metadata.summary> Payload, matching Python (spec R69 / finding A17).

=head2 schedule_local_activity

Emits a ScheduleLocalActivity command (sharing the activity seq space and pending-activity map) and returns the single stable cancellable awaitable that resolves on the local activity's terminal outcome (spec section 21).
Options are validated first under the same strictness rule as L</schedule_activity> (spec R35), against the local-activity key set (no C<task_queue>, C<heartbeat_timeout>, or C<priority>; C<local_retry_threshold> in addition). The backoff-to-server-timer retry loop is owned here: a C<backoff> resolution starts a timer and re-schedules under a new seq when it fires, leaving the returned future untouched.

=head2 start_child_workflow

Emits a StartChildWorkflowExecution command and returns the start awaitable that resolves to a L<Temporalio::Workflow::ChildWorkflowHandle> once the child has started (spec section 18).

=head2 start_timer

Emits a StartTimer command and returns the cancellable awaitable that resolves when the timer fires.
An optional C<summary> option is converted and placed on the command's C<user_metadata.summary> (spec R78).

=head2 upsert_search_attributes

Emits an UpsertWorkflowSearchAttributes command for the given typed updates (spec section 24) and updates the C<info-E<gt>{search_attributes}> view, converting every value before buffering so a conversion failure leaves no partial command. Empty updates emit no command; an untyped update raises L<Temporalio::Exception::Argument>.

=head2 upsert_memo

Emits a ModifyWorkflowProperties command for the given memo updates (spec section 24) and updates the C<info-E<gt>{memo}> view; an undef value removes the key (a null Payload). Empty updates emit no command; values are converted before buffering so a conversion failure leaves no partial command.

=head2 wait_condition

Registers a predicate to be re-checked as activations are applied, returning an awaitable that resolves when it holds.
An optional C<timeout> races it against a timer; C<timeout_summary> labels that timer's C<user_metadata.summary> (spec R78).

=head2 workflow_type

Returns the workflow type name of the execution.

=cut
