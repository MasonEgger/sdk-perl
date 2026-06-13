# ABOUTME: Fixture workflow that awaits an ABANDON-typed activity and lets a
# ABOUTME: Cancelled escape — drives T-act-9 (abandon): a CancelWorkflow job
# ABOUTME: cancels the workflow but, because the activity is abandon-typed, NO
# ABOUTME: RequestCancelActivity is emitted; the workflow still completes Cancelled.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::AbandonAwaiter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        # Awaits an activity scheduled with cancellation_type 'abandon'; a
        # CancelWorkflow job cancels the pending Future. Because the activity is
        # abandon-typed, the cancel emits no RequestCancelActivity (the workflow
        # stops waiting without telling core to cancel the activity). The
        # Cancelled propagates out of :Run -> CancelWorkflowExecution.
        my $r = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => ['x'],
            start_to_close_timeout => 60,
            cancellation_type      => 'abandon',
        );
        return $r;
    }
}

1;
