# ABOUTME: Fixture workflow that parks on a `done` signal — lets a replay test
# ABOUTME: inspect runner->info (start-time SAs/memo) before completion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run waits for `done`, so the run stays alive across the init activation. The
# test reads runner->info between activations to assert start-time search
# attributes / memo from the InitializeWorkflow job land in the info view.
class WfDef::InfoWaiter :isa(Temporalio::Workflow::Definition) {
    field $done = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $done });
        return 'ok';
    }

    method finish :Signal('done') () {
        $done = 1;
        return;
    }
}

1;
