# ABOUTME: Replay fixture (B3 / #5, t/replay/repro_cancel_wait_condition.t): a
# ABOUTME: workflow that parks on a
# ABOUTME: NEVER-TRUE wait_condition (no durable-timer workaround). A client
# ABOUTME: cancel must raise a throwable Temporalio::Exception::Cancelled into
# ABOUTME: the parked :Run so the body unwinds to CancelWorkflowExecution.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on wait_condition(sub { 0 }) — a predicate that is never true,
# so the only way out is cancellation. Before the B3 fix the parked
# wait_condition future was a plain (cancel-to-native) Future, so a client
# cancel surfaced a bare "was cancelled" string and failed the workflow task
# forever instead of routing to CancelWorkflowExecution. After the fix the
# condition future raises Temporalio::Exception::Cancelled, which escapes :Run
# and the runner emits CancelWorkflowExecution (gated on cancel_requested), so
# $handle->result raises WorkflowFailure with a Cancelled cause. This proves a
# never-true wait_condition is a promptly-cancellable park point WITHOUT the
# durable-timer workaround (cf. CancelChainWorkflow, which parks on a timer).
class WfDef::NeverCondition :isa(Temporalio::Workflow::Definition) {
    async method run :Run('NeverCondition') () {
        await Temporalio::Workflow::wait_condition(sub { 0 });
        return 'should-never-complete';
    }
}

1;
