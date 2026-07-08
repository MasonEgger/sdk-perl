# ABOUTME: Fixture workflow that starts a child, signals it, awaits the resolve,
# ABOUTME: THEN cancels the already-settled signal Future — proves no late/double
# ABOUTME: CancelSignalWorkflow is emitted (finding R10 / step R39 edge).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Workflow::Future;

# :Run starts a child, signals it via the handle, awaits the signal
# acknowledgement (ResolveSignalExternalWorkflow), and only THEN cancels the
# signal Future. Cancelling a ready Future is a no-op, so no
# CancelSignalWorkflow command may be emitted. The body then parks forever so
# the run stays open and the command stream can be asserted per activation.
class WfDef::ChildSignalResolvedCancel :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild', id => 'child-1');
        my $signal_future = $handle->signal('go');
        # Await the acknowledgement: the resolve settles the Future first.
        await $signal_future;
        # Cancel AFTER the resolve: a ready Future ignores ->cancel, so no
        # CancelSignalWorkflow command may appear (finding R10 edge).
        $signal_future->cancel;
        # Park forever so the run stays open across activations.
        await Temporalio::Workflow::Future->new;
        return 'unreachable';
    }
}

1;
