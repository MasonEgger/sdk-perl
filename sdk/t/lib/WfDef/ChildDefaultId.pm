# ABOUTME: Fixture workflow that starts a child WITHOUT an explicit id, so the
# ABOUTME: runner supplies a deterministic RNG-derived id — drives T-child-12
# ABOUTME: (the same randomness seed reproduces the id on re-run).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts a child with no id and returns the handle's id. Because the id
# is derived from the workflow RNG (seeded from the activation's randomness_seed),
# a re-run with the same seed produces the same id (replay determinism).
class WfDef::ChildDefaultId :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild');
        return $handle->id;
    }
}

1;
