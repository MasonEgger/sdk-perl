# ABOUTME: Fixture workflow that starts a child and cancels it when a "cancel"
# ABOUTME: signal arrives — drives explicit $handle->cancel (T-child-7) and the
# ABOUTME: cancellation_type echo. The child's cancellation_type is configurable.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts a child (whose cancellation_type the fixture sets) and parks on
# its result. A :Signal handler stashes the request to cancel; the body cancels
# the handle when the flag is set, which emits CancelChildWorkflowExecution
# (unless abandon). After cancellation the body awaits the result, which a
# ResolveChildWorkflowExecution{cancelled} settles to a ChildWorkflow/Cancelled.
class WfDef::ChildCanceller :isa(Temporalio::Workflow::Definition) {
    field $cancel_requested = 0;

    async method run :Run ($cancellation_type = 'wait_cancellation_completed') {
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild',
            id                => 'child-1',
            cancellation_type => $cancellation_type,
        );
        await Temporalio::Workflow::wait_condition(sub { $cancel_requested });
        $handle->cancel;
        return await $handle->result;
    }

    method want_cancel :Signal('cancel') (@args) {
        $cancel_requested = 1;
        return;
    }
}

1;
