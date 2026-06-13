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
use Temporalio::Exception::Nondeterminism ();
use Temporalio::Exception::Workflow::NoRunner ();

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

    # Pending activity Futures keyed by their command seq: { seq => $future }.
    # The Workflow::Future for each in-flight activity, resolved imperatively
    # when its ResolveActivity job arrives (P3.4). Child workflows (Phase 6+)
    # join analogous maps.
    field %pending_activities;

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
            # The patch ids the server has notified for this run (spec section
            # 10.3 "record in workflow info"). Sorted for a stable view.
            patches       => [ sort keys %patches_notified ],
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

        # Register the pending Future the body awaits; the runner resolves it
        # imperatively from the ResolveActivity job (never via IO::Async).
        my $future = Temporalio::Workflow::Future->new;
        $pending_activities{$seq} = $future;
        return $future;
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
        for my $job_set ($self->_ordered_job_sets($activation)) {
            next unless @$job_set;
            $self->_apply_job($_) for @$job_set;
            $self->_pump;
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
            values %in_progress_handlers)
        {
            $future->cancel unless $future->is_ready;
        }
        %pending_activities  = ();
        %pending_timers      = ();
        %in_progress_handlers = ();
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
    #   set 1: SignalWorkflow (+ updates in a later phase)
    #   set 2: every other non-query job (incl. InitializeWorkflow)
    #   set 3: QueryWorkflow (last; P4.2)
    method _ordered_job_sets ($activation) {
        my @sets = ([], [], [], []);
        for my $job ($activation->jobs->@*) {
            my $variant = $job->which_variant // '';
            if    ($variant eq 'notify_has_patch') { push $sets[0]->@*, $job }
            elsif ($variant eq 'signal_workflow')  { push $sets[1]->@*, $job }
            elsif ($variant eq 'query_workflow')   { push $sets[3]->@*, $job }
            else                                   { push $sets[2]->@*, $job }
        }
        return @sets;
    }

    method _apply_initialize ($init) {
        # Seed the deterministic RNG from the job (NOT the run id).
        $rng = _make_rng($init->randomness_seed // 0);

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

        # Fail every pending activity Future with Cancelled so the await site
        # raises a proper Temporal cancellation (a natively-cancelled Future
        # would surface a bare "was cancelled" string, losing the exception
        # identity — same reasoning as the timer Future override). Timer Futures
        # carry their own cancel override (emits CancelTimer + fails Cancelled),
        # so ->cancel them. Continuations run synchronously at resolve time, so
        # the body observes the cancellation before _pump/_build_completion.
        for my $seq (keys %pending_activities) {
            my $future = delete $pending_activities{$seq};
            next if !defined $future || $future->is_ready;
            $future->fail(Temporalio::Exception::Cancelled->new(
                message => 'Workflow execution cancelled',
            ));
        }
        for my $seq (keys %pending_timers) {
            my $future = $pending_timers{$seq};
            $future->cancel if defined $future && !$future->is_ready;
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

    # True when no signal handler is still in-flight (spec section 10.3 ASYNC
    # HANDLER TRACKING; MUST-match sdk-python workflow_all_handlers_finished).
    # Gates CompleteWorkflowExecution: the workflow is not considered complete
    # while a handler Future is pending.
    method _all_handlers_finished { return %in_progress_handlers ? 0 : 1 }

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
    method _pump {
        # Intentionally minimal: Future::AsyncAwait runs the body and fires its
        # on_ready continuations synchronously when the awaited futures are
        # already resolved, so there is nothing to drive for the skeleton. The
        # loop over pending_futures arrives with P3.4/P3.5.
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

        if (defined $main_run_future && $main_run_future->is_ready) {
            if (my @failure = $main_run_future->failure) {
                return $self->_outcome_for_failure($failure[0]);
            }
            # ASYNC HANDLER TRACKING (spec section 10.3): even when :Run has
            # returned, the workflow is NOT considered complete while a signal
            # handler Future is still in-flight. Emit only the buffered commands
            # this activation; a later activation that resolves the handler
            # Future re-pumps and then emits CompleteWorkflowExecution. (For
            # well-behaved workflows the body itself awaits the handler's effect,
            # so the run Future is not ready first — this gate is the safety net
            # mirroring sdk-python's all-handlers-finished accounting.)
            unless ($self->_all_handlers_finished) {
                return $self->_successful_completion;
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
        my $completion_class = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_completion.WorkflowActivationCompletion');
        return $completion_class->new({
            run_id     => $run_id,
            successful => { commands => [@commands] },
        });
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

1;

__END__

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
command + C<FireTimer> job, with C<CancelTimer> on Future cancel, P3.5), and the
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

=cut
