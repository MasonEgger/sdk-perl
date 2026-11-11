# ABOUTME: Spec F2 (GitHub issue #2): a :Signal handler failure must run
# ABOUTME: through the SAME ordered classification the main :Run body's own
# ABOUTME: failure runs through, not just its last two branches. I2 gave
# ABOUTME: _settle_signal only the workflow-failure / task-failure split, so a
# ABOUTME: Cancelled delivered by the cancel sweep, a continue-as-new control
# ABOUTME: signal, and a Nondeterminism were all misrouted. MUST-match
# ABOUTME: sdk-python _run_top_level_workflow_function
# ABOUTME: (worker/_workflow_instance.py:2518-2565).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;

no warnings 'experimental::class';

# ---------------------------------------------------------------------------
# Ground truth (../sdk-python temporalio/worker/_workflow_instance.py:2518-2565,
# _run_top_level_workflow_function). Python wraps the :Run body AND every
# signal / update handler coroutine in the same function, so one ordered
# classification serves all of them:
#
#   _ContinueAsNewError (:2521)            -> ContinueAsNewWorkflowExecution
#   self._deleting (:2528)                 -> swallow, emit nothing
#   CancelledError + _cancel_requested (:2556) -> CancelWorkflowExecution
#   workflow_is_failure_exception (:1820-1835) -> _set_workflow_failure
#                                             (:2558-2562), FailWorkflowExecution
#   anything else                          -> self._current_activation_error
#                                             (:2565), workflow TASK failure
#
# The Perl table matches that, with one Perl-only branch: Nondeterminism, which
# Python has no counterpart for here (it leaves non-determinism to sdk-core)
# while Perl's in-language determinism guard raises
# Temporalio::Exception::Nondeterminism, a Temporalio::Exception that would
# otherwise satisfy the generic workflow-failure branch. That branch already
# existed in Runner::_outcome_for_failure for the body, alongside continue-as-new
# and cancel; F2 extracts the whole table as Runner::_classify_failure, has
# _settle_signal consume it, and adds the `evicting` guard.
#
# One Perl branch deliberately does NOT emit what the body's does: 'cancelled'.
# See the deferral subtest below for why.
# ---------------------------------------------------------------------------

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# Init + a single signal that parks the handler on its own timer. Returns the
# harness so the caller can drive the activation that settles it.
sub parked_signal_harness ($signal_name, %opt) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalClassifier',
        %opt,
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalClassifier',
                arguments     => [],
            } },
        ],
    }));

    my @signalled = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => { signal_name => $signal_name, input => [] } },
        ],
    }));
    T2->is(scalar @signalled, 1,
        "the '$signal_name' handler parked on its own timer");
    T2->is($signalled[0]->which_variant, 'start_timer',
        "the '$signal_name' handler emitted a StartTimer before parking");

    return $harness;
}

# Init + a single signal whose handler is SYNCHRONOUS, so it settles inside the
# same activation that delivers it. Returns the resulting completion.
sub sync_signal_completion ($signal_name, %opt) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalClassifier',
        %opt,
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalClassifier',
                arguments     => [],
            } },
        ],
    }));

    return $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => { signal_name => $signal_name, input => [] } },
        ],
    }));
}

# ---------------------------------------------------------------------------
# Branch 3 (cancel-requested + Cancelled). THE I2 REGRESSION.
#
# _apply_cancel_workflow FAILS every parked timer with
# Temporalio::Exception::Cancelled, so a :Signal handler parked on sleep()
# resumes and its return Future fails with that Cancelled: a failure, not a
# native Future cancel, so _settle_signal's is_cancelled guard does not catch
# it. Pre-F2 the next check was _is_workflow_failure_exception, which accepts
# Cancelled (it isa Temporalio::Exception), so the HANDLER claimed the one-shot
# _emit_terminal_command slot with FailWorkflowExecution before the body's own
# Cancelled ever reached _outcome_for_failure's cancel branch. The workflow
# reported as FAILED on a clean cancel.
#
# Fixed, the handler settlement classifies the Cancelled and DEFERS; the single
# CancelWorkflowExecution asserted below comes from the body, whose never-true
# wait_condition the @conditions sweep cancels. The subtest after this one is
# the reason the handler may not emit it itself.
# ---------------------------------------------------------------------------
T2->subtest(
    'cancel with a parked async :Signal handler emits one Cancel and no Fail'
        => sub
{
    my $harness = parked_signal_harness('park');

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [ { cancel_workflow => {} } ],
    }));

    my @cancel = grep { $_->which_variant eq 'cancel_workflow_execution' }
        @commands;
    my @fail = grep { $_->which_variant eq 'fail_workflow_execution' }
        @commands;

    T2->is(scalar @fail, 0,
        'no FailWorkflowExecution: the handler Cancelled is a cancel, not a '
      . 'workflow failure');
    T2->is(scalar @cancel, 1,
        'exactly one CancelWorkflowExecution across the handler and the body');
});

# ---------------------------------------------------------------------------
# Branch 3, DEFERRAL arm. The body, not the handler, owns the run's single
# CancelWorkflowExecution.
#
# The handler resumes MID-SWEEP: _apply_cancel_workflow cancels %pending_timers
# third of eight sweeps, long before the @conditions sweep and the
# main-run-future fallback that resume the :Run body. A handler settlement that
# emitted the Cancel there would claim the one-shot terminal slot while the body
# is still unwinding, and a body that catches Cancelled and schedules post-cancel
# cleanup (the spec R8 / finding T8 contract, PostCancelTimer /
# PostCancelCleanup) would then have that cleanup command dropped by
# _repartition_after_terminal and its later CompleteWorkflowExecution suppressed:
# the run would close as Cancelled with the cleanup never scheduled. Worse, both
# frames park in %pending_timers, so WHICH of the two resumed first followed
# `keys %pending_timers` hash order, making the surviving command set vary run to
# run.
#
# So the 'cancelled' arm of the settlement defers. sdk-python never reaches this
# question: _apply_cancel_workflow (_workflow_instance.py:597-606) cancels only
# self._primary_task, so a workflow cancel is delivered to the body alone.
#
# The body always ends up emitting it. Either it is parked on something the
# sweep covers (here: a timer) and unwinds through _outcome_for_failure's cancel
# branch, or it is parked on something untracked, in which case the guarded
# main-run-future fallback cancels the run Future and _build_completion's
# is_cancelled arm routes a synthesized Cancelled through the same branch. That
# second route is already proven end to end by t/replay/repro_cancel_plain_future.t
# (finding R4b / spec R9). The third case, a body that already RETURNED, needs no
# emitter: the run closed on an earlier activation and _emit_terminal_command
# rations the slot to one per run, so deferring is the only correct answer there.
# ---------------------------------------------------------------------------
T2->subtest(
    'a cancel-resumed :Signal handler defers to the body, which keeps its '
  . 'post-cancel cleanup' => sub
{
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalCancelCleanup',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalCancelCleanup',
                arguments     => [],
            } },
        ],
    }));
    T2->is(scalar @init, 1, 'init parks the body on the Main timer');
    T2->is($init[0]->which_variant, 'start_timer', 'the body started a timer');

    my @signalled = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => { signal_name => 'park', input => [] } },
        ],
    }));
    T2->is(scalar @signalled, 1, 'the handler parked on a timer of its own');

    my @cancel = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [ { cancel_workflow => {} } ],
    }));

    my %count;
    $count{ $_->which_variant }++ for @cancel;

    T2->is($count{cancel_workflow_execution} // 0, 0,
        'the handler did NOT claim the terminal slot: no '
      . 'CancelWorkflowExecution while the body awaits its cleanup timer');
    T2->is($count{fail_workflow_execution} // 0, 0,
        'and no FailWorkflowExecution either');
    T2->is($count{start_timer} // 0, 1,
        'the body\'s post-cancel cleanup StartTimer survives the activation');

    # Both parked timers are cancelled by the sweep, in whichever order hash
    # order gave them; the count is order-independent, the sequence is not, so
    # assert only the count (Runner determinism, spec F2).
    T2->is($count{cancel_timer} // 0, 2,
        'both parked timers were cancelled by the sweep');

    my ($cleanup) = grep { $_->which_variant eq 'start_timer' } @cancel;
    my @fire = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 170 },
        jobs      => [ { fire_timer => { seq => $cleanup->start_timer->seq } } ],
    }));

    T2->is(scalar @fire, 1, 'the cleanup fire emits exactly one command');
    T2->is($fire[0]->which_variant, 'complete_workflow_execution',
        'the body completes normally after its cleanup ran: the deferred '
      . 'handler Cancelled never closed the run');
});

# ---------------------------------------------------------------------------
# Branch 2 (continue-as-new). Temporalio::Workflow::ContinueAsNew is
# deliberately NOT a Temporalio::Exception, so pre-F2 _settle_signal fell
# through to $current_activation_error and turned a legitimate continue-as-new
# into a workflow TASK failure the server retries forever.
# ---------------------------------------------------------------------------
T2->subtest('continue_as_new from a :Signal handler continues the run' => sub {
    my $completion = sync_signal_completion('again');

    T2->is($completion->which_status, 'successful',
        'continue-as-new is a control signal, not a task failure');

    my @commands = ($completion->successful->commands // [])->@*;
    my @can = grep {
        $_->which_variant eq 'continue_as_new_workflow_execution'
    } @commands;
    T2->is(scalar @can, 1, 'exactly one ContinueAsNewWorkflowExecution');
    T2->is($can[0]->continue_as_new_workflow_execution->workflow_type,
        'NextRun', 'the handler\'s continue_as_new options were carried');
});

# ---------------------------------------------------------------------------
# Branch 4 (Nondeterminism). Nondeterminism isa Temporalio::Exception, so the
# generic Temporal-failure branch would fail the EXECUTION. It must be tested
# ahead of that branch and fail the TASK, exactly as when it escapes :Run
# (Runner::_outcome_for_failure already ordered it that way for the body).
# ---------------------------------------------------------------------------
T2->subtest('a Nondeterminism from a :Signal handler fails the task' => sub {
    my $completion = sync_signal_completion('bad');

    T2->is($completion->which_status, 'failed',
        'a handler Nondeterminism fails the workflow TASK, not the execution');
    T2->like($completion->failed->failure->message,
        qr/nondeterminism from signal handler/,
        'the task failure carries the Nondeterminism message');
});

# The worker's opt-in policy arm. Both arms live in _build_completion's step 1,
# which the handler route reaches by recording $nondeterminism_error rather than
# emitting, so the handler route must honor the policy exactly as a
# non-determinism detected during job application does (T-wf-13).
T2->subtest(
    'nondeterminism_as_workflow_fail routes the same handler Nondeterminism '
  . 'to FailWorkflowExecution' => sub
{
    my $completion = sync_signal_completion('bad',
        nondeterminism_as_workflow_fail => 1);

    T2->is($completion->which_status, 'successful',
        'under the policy it fails the EXECUTION, so the completion itself is '
      . 'successful');
    my @commands = ($completion->successful->commands // [])->@*;
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'FailWorkflowExecution, not a workflow-task failure');
    T2->like($commands[0]->fail_workflow_execution->failure->message,
        qr/nondeterminism from signal handler/,
        'the workflow failure carries the Nondeterminism message');
});

# ---------------------------------------------------------------------------
# Branch 5 (Temporal failure type), async arm. The tracked
# %in_progress_handlers path settles on a LATER activation than the one that
# delivered the signal; it must reach the same FailWorkflowExecution the sync
# arm reaches (signal_handler_die.t covers the sync arm).
# ---------------------------------------------------------------------------
T2->subtest(
    'an async :Signal handler throwing an ApplicationError fails the execution'
        => sub
{
    my $harness = parked_signal_harness('app_async');

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));

    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'FailWorkflowExecution, not a workflow-task failure');
    my $failure = $commands[0]->fail_workflow_execution->failure;
    T2->like($failure->message, qr/app boom from async signal handler/,
        'the failure carries the async handler\'s message');
    T2->is($failure->application_failure_info->type, 'AsyncBoomError',
        'the failure carries the Application type');
});

# ---------------------------------------------------------------------------
# Branch 5, workflow_failure_exception_types arm (spec R14/R15, T-wf-15c). A
# non-Temporal class listed by the worker must fail the EXECUTION from a signal
# handler, the same as from :Run; unlisted, it falls to branch 6.
# ---------------------------------------------------------------------------
T2->subtest(
    'a workflow_failure_exception_types class from a :Signal handler fails '
  . 'the execution' => sub
{
    my $completion = sync_signal_completion('custom',
        workflow_failure_exception_types => [ 'WfDef::CustomError' ]);

    T2->is($completion->which_status, 'successful',
        'a listed class fails the EXECUTION, so the completion itself is '
      . 'successful');
    my @commands = ($completion->successful->commands // [])->@*;
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'FailWorkflowExecution for the listed class');
    T2->like($commands[0]->fail_workflow_execution->failure->message,
        qr/custom boom from signal handler/,
        'the failure carries the custom class\'s message');
});

T2->subtest(
    'the same class UNLISTED from a :Signal handler fails only the task'
        => sub
{
    my $completion = sync_signal_completion('custom');

    T2->is($completion->which_status, 'failed',
        'unlisted, the custom class falls to the task-failure branch');
    T2->like($completion->failed->failure->message,
        qr/custom boom from signal handler/,
        'the task failure carries the custom class\'s message');
});

# ---------------------------------------------------------------------------
# Branch 1 (evicting). evict() tears the run down: it cancels every parked
# timer, which resumes each parked handler frame. Those settlements must emit
# NOTHING and record NOTHING, matching sdk-python's self._deleting guard and
# the drop rule _update_settlement already applies to a natively cancelled
# update handler.
#
# evict() builds no completion of its own (WorkflowDispatcher::_handle_eviction
# sends a fixed empty success and drops the runner), so the drop rule is
# asserted as WHITE-BOX runner state, through one probe activation pushed after
# the evict. Two handlers are parked so both halves of the rule are exercised
# in one run:
#
#   - `park` unwinds with the Cancelled its cancelled timer raises. Pre-F2 that
#     Cancelled passed _is_workflow_failure_exception and the settlement pushed
#     FailWorkflowExecution, claiming the one-shot terminal slot.
#   - `park_catch` swallows that Cancelled and dies with a plain string. Pre-F2
#     that landed in $current_activation_error, which is run-scoped (never
#     cleared per activation), so the probe came back `failed` carrying the
#     teardown message.
#
# Fixed, the probe is the empty successful completion: the evicted runner emits
# no command and reports no failure, on this activation or any other.
# ---------------------------------------------------------------------------
T2->subtest('evict with parked :Signal handlers emits and records nothing'
        => sub
{
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalClassifier',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalClassifier',
                arguments     => [],
            } },
        ],
    }));

    my @parked = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => { signal_name => 'park',       input => [] } },
            { signal_workflow => { signal_name => 'park_catch', input => [] } },
        ],
    }));
    T2->is(scalar @parked, 2,
        'both handlers parked on their own timers before the eviction');

    $harness->runner->evict;

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 120 },
        jobs      => [],
    }));

    T2->is($completion->which_status, 'successful',
        'the eviction settlements recorded no activation error: the plain die '
      . 'raised while evict() tore a handler down is dropped, not turned into '
      . 'a workflow task failure');
    T2->is(scalar(($completion->successful->commands // [])->@*), 0,
        'and the evicted runner emits no command: no FailWorkflowExecution '
      . 'from the handler Cancelled, and nothing claimed the one-shot '
      . 'terminal slot');
});

# ---------------------------------------------------------------------------
# Spec R13 re-partition. A handler settlement claims the terminal slot MID
# activation, so any command pushed by a later job in the SAME activation lands
# AFTER it. Core rejects a command list with anything past the workflow-terminal
# command. The R13 keep-list is the handler RESPONSES; the state-mutating
# commands the server will never act on past the terminal are dropped, and the
# terminal command ends up last.
# ---------------------------------------------------------------------------
T2->subtest(
    'commands pushed after a handler-emitted terminal are re-partitioned'
        => sub
{
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::SignalTerminalPartition',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'SignalTerminalPartition',
                arguments     => [],
            } },
        ],
    }));

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => { signal_name => 'app',  input => [] } },
            { signal_workflow => { signal_name => 'work', input => [] } },
            { query_workflow  => {
                query_id   => 'q-1',
                query_type => 'peek',
                arguments  => [],
            } },
        ],
    }));

    T2->is(scalar @commands, 2,
        'the StartTimer pushed after the terminal command is dropped');
    T2->is([ map { $_->which_variant } @commands ],
        [ 'respond_to_query', 'fail_workflow_execution' ],
        'the query response survives and the terminal command is last');
});

T2->done_testing;
