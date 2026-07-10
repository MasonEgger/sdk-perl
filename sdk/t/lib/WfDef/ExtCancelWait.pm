# ABOUTME: Fixture workflow for R10 (finding R4c, external-cancel map): requests
# ABOUTME: cancellation of an external workflow and parks on the acknowledgement
# ABOUTME: Future; on a whole-workflow cancel it must observe Cancelled and return.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The external-cancel-map shape of the R4c probe (spec R10):
# %pending_external_cancels was never swept by _apply_cancel_workflow, exactly
# like %pending_external_signals in WfDef::ExtSignalWait.
class WfDef::ExtCancelWait :isa(Temporalio::Workflow::Definition) {
    async method run :Run('ExtCancelWait') () {
        my $h = Temporalio::Workflow::get_external_workflow_handle('ext-target');
        my $ok = eval { await $h->cancel; 1 };
        return 'cancel-acked' if $ok;

        my $err = $@;
        return 'observed-cancelled'
            if Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Cancelled');
        die $err;    ## no critic (ErrorHandling::RequireCarping)
    }
}

1;
