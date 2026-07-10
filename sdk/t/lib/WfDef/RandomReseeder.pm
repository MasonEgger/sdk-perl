# ABOUTME: Fixture workflow that draws RNG values across two activations to drive
# ABOUTME: the UpdateRandomSeed re-seed path in determinism.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run draws two RNG integers, parks on a timer, then (after the timer fires
# on a later activation that may carry an UpdateRandomSeed job) draws two more.
# Returning the four values lets the test assert that an UpdateRandomSeed job
# re-seeds the generator (the post-fire draws differ from what the original seed
# would have produced) while staying deterministic for a given seed pair.
class WfDef::RandomReseeder :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $rng = Temporalio::Workflow::random();
        my @before = ($rng->irand, $rng->irand);
        await Temporalio::Workflow::sleep(1);
        # Re-fetch the generator: an UpdateRandomSeed job replaces it.
        my $rng2 = Temporalio::Workflow::random();
        my @after = ($rng2->irand, $rng2->irand);
        return { before => \@before, after => \@after };
    }
}

1;
