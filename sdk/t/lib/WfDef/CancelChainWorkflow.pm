# ABOUTME: LIVE integration fixture (P5.1): a workflow that parks on a long timer
# ABOUTME: then gets cancelled. A client cancel arrives promptly as a
# ABOUTME: CancelWorkflow job; the runner cancels the pending timer Future
# ABOUTME: (emitting CancelTimer), Cancelled escapes :Run, and the workflow ends
# ABOUTME: Cancelled (T-cli-cancel-1 / T-wf-12 end-to-end).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::CancelChainWorkflow :isa(Temporalio::Workflow::Definition) {
    # Sleep on a long timer; a client cancel arrives as a CancelWorkflow job,
    # the runner cancels the timer Future (emitting CancelTimer) which raises
    # Cancelled here. The Cancelled propagates out of :Run -> the runner emits
    # CancelWorkflowExecution (gated on cancel_requested), and the client's
    # $handle->result raises WorkflowFailure with a Cancelled cause. The timer
    # is the deterministic, promptly-cancellable park point (a parked activity
    # would only learn of the cancel via its heartbeat response, which the dev
    # server delivers batched with the activity resolution rather than promptly).
    async method run :Run('CancelChainWorkflow') () {
        await Temporalio::Workflow::sleep(120);
        return 'completed-without-cancel';
    }
}

1;
