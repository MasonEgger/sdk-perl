# ABOUTME: Fixture workflow that starts a child via start_child_workflow and
# ABOUTME: returns the handle's first_execution_run_id once started (without
# ABOUTME: awaiting the result) — drives start-only resolution (T-child-2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run awaits start_child_workflow (suspending until the start job arrives)
# and then returns the started child's run id WITHOUT awaiting its result. This
# proves a start-only workflow completes on ResolveChildWorkflowExecutionStart
# while an execute-style workflow (WfDef::ChildCaller) stays parked.
class WfDef::ChildStarter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild',
            id   => 'child-1',
            args => ['Bob'],
        );
        return $handle->first_execution_run_id;
    }
}

1;
