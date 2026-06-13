# ABOUTME: Fixture workflow that awaits an activity and lets a Cancelled escape —
# ABOUTME: drives T-wf-12: a CancelWorkflow job cancels the pending activity Future,
# ABOUTME: the Cancelled propagates out of :Run, and the outcome is
# ABOUTME: CancelWorkflowExecution (NOT FailWorkflowExecution).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::CancelAwaiter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        # Awaits an activity that never resolves; a CancelWorkflow job cancels
        # the pending Future, raising Temporalio::Exception::Cancelled here,
        # which is allowed to propagate out of :Run.
        my $r = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => ['x'],
            start_to_close_timeout => 60,
        );
        return $r;
    }
}

1;
