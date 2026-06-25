# ABOUTME: Fixture workflow that uses ONLY the SDK's deterministic primitives
# ABOUTME: (Workflow::now / time / random) - the guard must NEVER trap these,
# ABOUTME: even with $Runner::CURRENT set (T-det-4: self-exemption).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run draws the activation timestamp via Workflow::time and an RNG value via
# Workflow::random. Neither touches the trapped CORE builtins, so the body must
# complete normally with the guard installed (T-det-4).
class WfDef::SafeNow :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $t   = Temporalio::Workflow::time();
        my $rng = Temporalio::Workflow::random();
        return { t => $t, r => $rng->irand };
    }
}

1;
