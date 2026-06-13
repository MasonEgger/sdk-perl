# ABOUTME: Replay tests for the completion-outcome decision table (spec section
# ABOUTME: 10.3 step 6): cancel (T-wf-12), task-fail vs workflow-fail (T-wf-15a/b/c),
# ABOUTME: continue_as_new (T-wf-8), and unknown-seq non-determinism (T-wf-13).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;

no warnings 'experimental::class';

# Build a WorkflowActivation proto. The job list is the oneof-tagged hashref
# form the generated classes accept.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;
sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# T-wf-11 baseline: a normal return is CompleteWorkflowExecution with the
# result payload. (Anchors the success arm of the decision table.)
# ---------------------------------------------------------------------------
T2->subtest('normal return -> CompleteWorkflowExecution (T-wf-11)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Plain',
    );
    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'execute',
                arguments     => [ payload(7) ],
            } },
        ],
    }));
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'complete_workflow_execution',
        'CompleteWorkflowExecution');
    T2->is($PC->from_payload($commands[0]->complete_workflow_execution->result),
        'plain:7', 'result payload carries the return value');
});

# ---------------------------------------------------------------------------
# T-wf-15a: a plain string `die` is a workflow-TASK failure: the completion's
# status is `failed` (the worker reports a WFT failure the server retries), and
# the workflow execution is NOT failed (no FailWorkflowExecution command).
# ---------------------------------------------------------------------------
T2->subtest('plain die -> task failure, workflow NOT failed (T-wf-15a)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TaskFailer',
    );
    my $completion = $harness->push_activation_completion(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [
            { initialize_workflow => { workflow_type => 'run' } },
        ],
    }));

    T2->is($completion->which_status, 'failed',
        'completion status is failed (workflow-task failure)');
    my $failure = $completion->failed->failure;
    T2->ok(defined $failure, 'failed carries a Failure proto');
    T2->like($failure->message, qr/boom/, 'failure message preserved');

    # And NO commands (the workflow execution is not completed/failed).
    my @commands = $harness->commands_of($completion);
    T2->is(scalar @commands, 0, 'no FailWorkflowExecution command emitted');
});

# ---------------------------------------------------------------------------
# T-wf-15b: a Temporalio::Exception::Application escaping :Run FAILS THE
# WORKFLOW EXECUTION: the completion is successful and its sole command is
# FailWorkflowExecution carrying the converted failure.
# ---------------------------------------------------------------------------
T2->subtest('Application error -> FailWorkflowExecution (T-wf-15b)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::AppFailer',
    );
    my @commands = $harness->push_activation(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [ { initialize_workflow => { workflow_type => 'run' } } ],
    }));
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'FailWorkflowExecution');
    my $failure = $commands[0]->fail_workflow_execution->failure;
    T2->like($failure->message, qr/app boom/, 'failure message preserved');
    T2->is($failure->application_failure_info->type, 'BoomError',
        'failure carries the Application type');
});

# ---------------------------------------------------------------------------
# T-wf-15c: a NON-Temporal class fails the workflow ONLY when its class is in
# the worker's workflow_failure_exception_types. Listed -> FailWorkflowExecution;
# unlisted -> task failure.
# ---------------------------------------------------------------------------
T2->subtest('listed non-Temporal class -> FailWorkflowExecution (T-wf-15c)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class                   => 'WfDef::CustomFailer',
        workflow_failure_exception_types => ['WfDef::CustomError'],
    );
    my @commands = $harness->push_activation(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [ { initialize_workflow => { workflow_type => 'run' } } ],
    }));
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'listed class fails the workflow');
    T2->like($commands[0]->fail_workflow_execution->failure->message,
        qr/custom boom/, 'failure message preserved');
});

T2->subtest('unlisted non-Temporal class -> task failure (T-wf-15c)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::CustomFailer',
        # no workflow_failure_exception_types
    );
    my $completion = $harness->push_activation_completion(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [ { initialize_workflow => { workflow_type => 'run' } } ],
    }));
    T2->is($completion->which_status, 'failed',
        'unlisted class is a task failure (completion failed)');
    T2->like($completion->failed->failure->message, qr/custom boom/,
        'failure message preserved');
});

# ---------------------------------------------------------------------------
# T-wf-8: continue_as_new -> the sole command is ContinueAsNewWorkflowExecution
# carrying the new args and the type/task_queue overrides. NOT a completion.
# ---------------------------------------------------------------------------
T2->subtest('continue_as_new -> ContinueAsNewWorkflowExecution (T-wf-8)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ContinueAsNewer',
    );
    my @commands = $harness->push_activation(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [
            { initialize_workflow => {
                workflow_type => 'run',
                arguments     => [ payload(1) ],
            } },
        ],
    }));
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'continue_as_new_workflow_execution',
        'ContinueAsNewWorkflowExecution');
    my $can = $commands[0]->continue_as_new_workflow_execution;
    T2->is($can->workflow_type, 'NextRun', 'carries the new workflow type');
    T2->is($can->task_queue, 'next-queue', 'carries the new task queue');
    my @args = ($can->arguments // [])->@*;
    T2->is(scalar @args, 1, 'one continue-as-new argument');
    T2->is($PC->from_payload($args[0]), 2, 'argument is the incremented counter');
});

# ---------------------------------------------------------------------------
# T-wf-12: a CancelWorkflow job cancels the pending activity Future, the
# Cancelled propagates out of :Run, and the outcome is CancelWorkflowExecution
# (de facto spec: NOT FailWorkflowExecution).
# ---------------------------------------------------------------------------
T2->subtest('CancelWorkflow -> CancelWorkflowExecution (T-wf-12)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::CancelAwaiter',
    );

    # First activation: schedules the activity and parks on its Future.
    my @first = $harness->push_activation(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [ { initialize_workflow => { workflow_type => 'run' } } ],
    }));
    T2->is($first[0]->which_variant, 'schedule_activity',
        'first activation schedules the activity');

    # Second activation: CancelWorkflow cancels the pending activity Future.
    my @second = $harness->push_activation(activation({
        run_id => 'r1',
        timestamp => { seconds => 2 },
        jobs => [ { cancel_workflow => {} } ],
    }));
    T2->is(scalar @second, 1, 'one command after cancellation');
    T2->is($second[0]->which_variant, 'cancel_workflow_execution',
        'CancelWorkflowExecution (not a failure)');
});

# ---------------------------------------------------------------------------
# T-wf-13: a ResolveActivity for an unknown seq is a non-determinism error.
# By default (nondeterminism_as_workflow_fail off) it is a TASK failure; with
# the flag set it FAILS THE WORKFLOW (FailWorkflowExecution).
# ---------------------------------------------------------------------------
T2->subtest('unknown-seq resolution -> task failure by default (T-wf-13)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Plain',
    );
    my $completion = $harness->push_activation_completion(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [
            { initialize_workflow => {
                workflow_type => 'execute',
                arguments     => [ payload(1) ],
            } },
            { resolve_activity => { seq => 99, result => { completed => {} } } },
        ],
    }));
    T2->is($completion->which_status, 'failed',
        'unknown seq is a task failure by default');
    T2->like($completion->failed->failure->message, qr/99|non-?determin/i,
        'failure mentions the offending seq / non-determinism');
});

T2->subtest('unknown-seq resolution -> workflow fail when configured (T-wf-13)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class                 => 'WfDef::Plain',
        nondeterminism_as_workflow_fail => 1,
    );
    my @commands = $harness->push_activation(activation({
        run_id => 'r1',
        timestamp => { seconds => 1 },
        jobs => [
            { initialize_workflow => {
                workflow_type => 'execute',
                arguments     => [ payload(1) ],
            } },
            { resolve_activity => { seq => 99, result => { completed => {} } } },
        ],
    }));
    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'non-determinism fails the workflow when configured');
});

T2->done_testing;
