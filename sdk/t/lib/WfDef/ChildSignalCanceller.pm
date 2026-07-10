# ABOUTME: Fixture workflow that starts a child, signals it via the handle, then
# ABOUTME: cancels the in-flight signal Future — drives CancelSignalWorkflow on
# ABOUTME: the child_workflow_id signal arm (finding R10 / step R39).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Workflow::Future;

# :Run starts a child, sends it a signal through the handle (emitting a
# SignalExternalWorkflowExecution on the child_workflow_id oneof arm), then
# cancels the signal's in-flight Future before the resolve arrives. Cancelling
# it must emit CancelSignalWorkflow{seq} — parity with the external-handle arm
# (WfDef::ExternalSignalCanceller / T-ext-9) — and must NOT pre-emptively raise:
# the eventual ResolveSignalExternalWorkflow settles it. The body then parks
# forever so the run stays open across activations.
class WfDef::ChildSignalCanceller :isa(Temporalio::Workflow::Definition) {
    field $signal_future;

    async method run :Run () {
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild', id => 'child-1');
        $signal_future = $handle->signal('go');
        # Cancel the in-flight child-signal frame: must emit
        # CancelSignalWorkflow{seq} (finding R10).
        $signal_future->cancel;
        # Park forever so the run stays open across activations.
        await Temporalio::Workflow::Future->new;
        return 'unreachable';
    }
}

1;
