# ABOUTME: Fixture workflow that starts a child, signals it via the handle, then
# ABOUTME: awaits the result — drives the child_workflow_id signal arm (T-child-9).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts a child, sends it a signal through the handle (which emits a
# SignalExternalWorkflowExecution on the child_workflow_id oneof arm), awaits
# the signal acknowledgement, then awaits the child result.
class WfDef::ChildSignaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild', id => 'child-1');
        await $handle->signal('go', args => ['x']);
        return await $handle->result;
    }
}

1;
