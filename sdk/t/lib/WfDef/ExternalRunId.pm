# ABOUTME: Fixture workflow that signals AND cancels an external handle carrying
# ABOUTME: an explicit run_id — drives run_id threading (T-ext-8).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run resolves an external handle with an explicit run_id, emits one signal and
# one cancel (both targeting that run_id), then awaits both.
class WfDef::ExternalRunId :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h = Temporalio::Workflow::get_external_workflow_handle(
            'other-wf', run_id => 'run-abc');
        my $s = $h->signal('go');
        my $c = $h->cancel;
        await $s;
        await $c;
        return 'done';
    }
}

1;
