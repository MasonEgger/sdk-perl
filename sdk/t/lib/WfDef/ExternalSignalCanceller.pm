# ABOUTME: Fixture workflow that starts an external signal then cancels the
# ABOUTME: awaiting frame via a timer race — drives CancelSignalWorkflow (T-ext-9).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run starts an external signal, then cancels its in-flight Future before the
# resolve arrives. Cancelling the signal Future emits CancelSignalWorkflow{seq}
# but does NOT pre-emptively raise — the eventual ResolveSignalExternalWorkflow
# settles it. The signal Future is stored on the instance so a later activation
# can be reasoned about; here the body just cancels then parks forever on a
# never-resolved condition so the run does not complete prematurely.
class WfDef::ExternalSignalCanceller :isa(Temporalio::Workflow::Definition) {
    field $signal_future;

    async method run :Run () {
        my $h = Temporalio::Workflow::get_external_workflow_handle('other-wf');
        $signal_future = $h->signal('go');
        # Cancel the in-flight signal frame: emits CancelSignalWorkflow{seq}.
        $signal_future->cancel;
        # Park forever so the run stays open across activations.
        await Temporalio::Workflow::Future->new;
        return 'unreachable';
    }
}

1;
