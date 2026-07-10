# ABOUTME: Fixture workflow for R10 (finding R4c, external-signal map): signals an
# ABOUTME: external workflow and parks on the acknowledgement Future; on a
# ABOUTME: whole-workflow cancel it must observe Cancelled and return a marker.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The R4c probe body (spec R10): %pending_external_signals was never swept by
# _apply_cancel_workflow, so pre-fix this park was only reachable through the
# main-run-future fallback and push_activation died ("was cancelled"); fixed,
# the sweep fails the signal Future with Cancelled and the body returns.
class WfDef::ExtSignalWait :isa(Temporalio::Workflow::Definition) {
    async method run :Run('ExtSignalWait') () {
        my $h = Temporalio::Workflow::get_external_workflow_handle('ext-target');
        my $ok = eval { await $h->signal('go'); 1 };
        return 'signalled' if $ok;

        my $err = $@;
        return 'observed-cancelled'
            if Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Cancelled');
        die $err;    ## no critic (ErrorHandling::RequireCarping)
    }
}

1;
