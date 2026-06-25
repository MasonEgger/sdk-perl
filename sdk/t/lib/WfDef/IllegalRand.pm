# ABOUTME: Fixture workflow whose body calls the core `rand` builtin directly,
# ABOUTME: which the determinism guard must trap as Nondeterminism (T-det-1).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run calls CORE `rand` (unqualified) inside workflow context. With the
# guard installed and $Runner::CURRENT set, this throws Nondeterminism. The
# SDK's own deterministic generator is Temporalio::Workflow::random, never rand.
class WfDef::IllegalRand :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $r = rand;
        return $r;
    }
}

1;
