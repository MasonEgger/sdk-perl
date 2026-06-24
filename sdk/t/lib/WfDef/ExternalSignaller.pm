# ABOUTME: Fixture workflow that gets an external handle and signals it once —
# ABOUTME: drives the workflow_execution signal arm (T-ext-1..4).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run resolves an external handle to a fixed workflow id, sends it one signal
# (SignalExternalWorkflowExecution on the workflow_execution oneof arm), awaits
# the acknowledgement, and returns the handle's id.
class WfDef::ExternalSignaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h = Temporalio::Workflow::get_external_workflow_handle('other-wf');
        await $h->signal('go', args => ['x']);
        return $h->workflow_id;
    }
}

1;
