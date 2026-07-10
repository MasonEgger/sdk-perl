# ABOUTME: Fixture workflow that gets an external handle and cancels it —
# ABOUTME: drives RequestCancelExternalWorkflowExecution (T-ext-5..6).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run resolves an external handle and requests its cancellation, awaiting the
# ResolveRequestCancelExternalWorkflow acknowledgement.
class WfDef::ExternalCanceller :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h = Temporalio::Workflow::get_external_workflow_handle('other-wf');
        await $h->cancel;
        return 'cancelled';
    }
}

1;
