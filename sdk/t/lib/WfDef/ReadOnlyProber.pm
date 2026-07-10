# ABOUTME: Fixture workflow whose :Query handler calls one of the four APIs that
# ABOUTME: bypassed the read-only guard (finding R8 / step R24): patched,
# ABOUTME: child-handle signal, external-handle signal, external-handle cancel.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run starts a child (so the query handler has a live ChildWorkflowHandle for
# the child-signal arm) and parks on a long timer so the run stays open across
# activations. The 'probe' :Query is table-driven by its argument: it calls one
# of the four command-emitting APIs from query (read-only) context. Every arm
# MUST raise the typed read-only error (Temporalio::Exception::ReadOnly);
# reaching the final return means the guard failed to fire (the pre-R24
# defect: the API silently emitted a command from a query).
class WfDef::ReadOnlyProber :isa(Temporalio::Workflow::Definition) {
    field $child_handle;

    async method run :Run () {
        $child_handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild', id => 'child-1');
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }

    method probe :Query('probe') ($api) {
        if ($api eq 'patched') {
            Temporalio::Workflow::patched('ro-patch');
        }
        elsif ($api eq 'child_signal') {
            $child_handle->signal('go');
        }
        elsif ($api eq 'external_signal') {
            Temporalio::Workflow::get_external_workflow_handle('ext-target')
                ->signal('go');
        }
        elsif ($api eq 'external_cancel') {
            Temporalio::Workflow::get_external_workflow_handle('ext-target')
                ->cancel;
        }
        else {
            die "ReadOnlyProber: unknown probe api '$api'";
        }
        return 'guard-did-not-fire';
    }
}

1;
