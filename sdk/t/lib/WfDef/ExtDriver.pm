# ABOUTME: Integration driver workflow — gets an external handle to a target by
# ABOUTME: id, signals it then cancels it (or signals a bogus id). Drives T-ext-10.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Driven by ($mode, $target_id):
#   'signal_cancel' -> get an external handle to $target_id, signal it 'go',
#                      then request its cancellation, and return 'done'.
#   'missing'       -> signal a non-existent workflow id; the
#                      ResolveSignalExternalWorkflow failure surfaces as an
#                      Exception::Application, which propagates out of :Run.
class WfDef::ExtDriver :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($mode = 'signal_cancel', $target_id = '') {
        my $h = Temporalio::Workflow::get_external_workflow_handle($target_id);
        if ($mode eq 'missing') {
            await $h->signal('go', args => ['x']);
            return 'sent';
        }
        await $h->signal('go', args => ['x']);
        await $h->cancel;
        return 'done';
    }
}

1;
