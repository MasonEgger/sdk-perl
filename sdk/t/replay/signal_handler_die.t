# ABOUTME: A die inside a :Signal handler (sync or async) must fail the
# ABOUTME: workflow TASK (spec §I2, GitHub issue #2), never a silent normal
# ABOUTME: completion, UNLESS the exception is a Temporal failure type (or a
# ABOUTME: configured workflow_failure_exception_types class), which fails the
# ABOUTME: workflow EXECUTION instead. MUST-match sdk-python: a signal handler
# ABOUTME: exception runs through _run_top_level_workflow_function
# ABOUTME: (worker/_workflow_instance.py:2518-2565), which classifies via
# ABOUTME: workflow_is_failure_exception (:1820-1835): a Temporal failure type
# ABOUTME: -> _set_workflow_failure (:2560-2562, FailWorkflowExecution); anything
# ABOUTME: else -> self._current_activation_error (:2563-2565, the
# ABOUTME: workflow-TASK-failure route; signals have no response channel to
# ABOUTME: reject).
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

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# ---------------------------------------------------------------------------
# A synchronous :Signal handler that dies must fail the workflow TASK: the
# already-ready failed Future->call result was previously untracked and
# unobserved (Runner.pm _dispatch_signal, pre-fix), so the activation produced
# a normal completion with no commands instead of a failed one.
# ---------------------------------------------------------------------------
T2->subtest('a dying sync :Signal handler fails the workflow task' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DyingSignal',
    );

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DyingSignal',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'boom',
                input       => [],
            } },
        ],
    }));

    T2->is($completion->which_status, 'failed',
        'the completion is a workflow-TASK failure, not a normal completion');
    T2->like($completion->failed->failure->message, qr/boom in sync signal/,
        'the failure carries the dying handler\'s message');
});

# ---------------------------------------------------------------------------
# An async :Signal handler that dies (its Future settles LATER, once tracked
# in %in_progress_handlers) must ALSO fail the workflow task: the tracked arm
# is a separate code path from the sync arm and needs its own coverage.
# ---------------------------------------------------------------------------
T2->subtest('a dying async :Signal handler fails the workflow task' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DyingAsyncSignal',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DyingAsyncSignal',
                arguments     => [],
            } },
        ],
    }));
    T2->is(scalar @init, 0, 'the run parks on wait_condition; no commands yet');

    my @signalled = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 105 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'boom',
                input       => [],
            } },
        ],
    }));
    T2->is(scalar @signalled, 1, 'the async handler parked on its own timer');
    T2->is($signalled[0]->which_variant, 'start_timer',
        'the handler emitted a StartTimer before dying');

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));

    T2->is($completion->which_status, 'failed',
        'the completion is a workflow-TASK failure once the handler dies');
    T2->like($completion->failed->failure->message, qr/boom in async signal/,
        'the failure carries the dying async handler\'s message');
});

# ---------------------------------------------------------------------------
# A synchronous :Signal handler that throws a Temporal failure-type exception
# (Temporalio::Exception::Application) must fail the workflow EXECUTION
# (FailWorkflowExecution), not the workflow task. MUST-match sdk-python
# workflow_is_failure_exception classifying the same exception the same way
# whether it escapes the main :Run body or a signal handler.
# ---------------------------------------------------------------------------
T2->subtest(
    'a sync :Signal handler throwing a Temporal failure fails the workflow execution'
        => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DyingSignalFailure',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DyingSignalFailure',
                arguments     => [],
            } },
            { signal_workflow => {
                signal_name => 'boom',
                input       => [],
            } },
        ],
    }));

    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'FailWorkflowExecution, not a workflow-task failure');
    my $failure = $commands[0]->fail_workflow_execution->failure;
    T2->like($failure->message, qr/app boom in sync signal/,
        'the failure carries the dying handler\'s message');
    T2->is($failure->application_failure_info->type, 'BoomError',
        'failure carries the Application type');
});

T2->done_testing;
