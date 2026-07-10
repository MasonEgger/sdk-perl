# ABOUTME: Fixture workflow that captures Temporalio::Workflow context state
# ABOUTME: (now/time/is_replaying/info/random) inside its :Run for replay tests.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run reads the deterministic workflow-context accessors and returns them
# in a hashref. Because these must come from the activation (never the OS
# clock), the runner sets $Temporalio::Workflow::Runner::CURRENT around the
# body via Syntax::Keyword::Dynamically before invoking this method.
class WfDef::Clock :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $rng = Temporalio::Workflow::random();
        return {
            time         => Temporalio::Workflow::time(),
            now_epoch    => Temporalio::Workflow::now()->epoch,
            is_replaying => Temporalio::Workflow::is_replaying() ? 1 : 0,
            run_id       => Temporalio::Workflow::info()->{run_id},
            workflow_type => Temporalio::Workflow::info()->{workflow_type},
            rng          => [ map { $rng->irand } 1 .. 4 ],
        };
    }
}

1;
