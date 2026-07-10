# ABOUTME: LIVE integration fixture (P5.1): a workflow that starts an
# ABOUTME: ABANDON-typed activity (without awaiting it) and then parks on a long
# ABOUTME: timer. On client cancel the timer Future is cancelled and the workflow
# ABOUTME: ends Cancelled; because the activity is abandon-typed, cancelling its
# ABOUTME: Future emits NO RequestCancelActivity — the activity is left running
# ABOUTME: (orphaned/abandoned) (T-act-9 abandon end-to-end).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::AbandonCancelWorkflow :isa(Temporalio::Workflow::Definition) {
    # Start an abandon-typed activity (start_activity, not awaited so the body
    # keeps running) then park on a long timer. A client cancel cancels BOTH
    # pending Futures: the timer (emitting CancelTimer) AND the abandon activity
    # (emitting NO RequestCancelActivity — the abandon contract). The timer's
    # Cancelled escapes :Run -> CancelWorkflowExecution. The activity is never
    # told to cancel and runs to its own (bounded) completion.
    async method run :Run('AbandonCancelWorkflow') () {
        # Fire-and-forget the abandon activity; keep the handle so it is a
        # pending activity Future the cancel chain will reach.
        my $activity = Temporalio::Workflow::start_activity(
            'AbandonActivity',
            args                   => [],
            start_to_close_timeout => 120,
            cancellation_type      => 'abandon',
        );
        await Temporalio::Workflow::sleep(120);
        await $activity;
        return 'completed-without-cancel';
    }
}

1;
