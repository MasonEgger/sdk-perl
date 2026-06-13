# ABOUTME: Fixture workflow whose :Run calls Temporalio::Workflow::continue_as_new
# ABOUTME: — drives the ContinueAsNewWorkflowExecution outcome (T-wf-8): the
# ABOUTME: control-flow signal escapes :Run and becomes the final command.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::ContinueAsNewer :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($n = 1) {
        # Continue as new with an incremented counter and an explicit override
        # of the workflow type + task queue (per spec: continue_as_new does NOT
        # re-use the old arguments; type/task_queue are carried when set).
        Temporalio::Workflow::continue_as_new(
            'NextRun',
            args       => [ $n + 1 ],
            task_queue => 'next-queue',
        );
        return 'unreachable';
    }
}

1;
