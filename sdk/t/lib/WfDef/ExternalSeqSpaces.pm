# ABOUTME: Fixture workflow that fires two external signals then one cancel on an
# ABOUTME: external handle — drives independent seq spaces (T-ext-7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run starts two signals and one cancel concurrently (without awaiting between
# emissions) so all three commands are buffered in one activation: external
# signals take seq 1 and 2, the cancel takes seq 1 in its own space. The body
# then awaits all three.
class WfDef::ExternalSeqSpaces :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h  = Temporalio::Workflow::get_external_workflow_handle('other-wf');
        my $s1 = $h->signal('one');
        my $s2 = $h->signal('two');
        my $c1 = $h->cancel;
        await $s1;
        await $s2;
        await $c1;
        return 'done';
    }
}

1;
