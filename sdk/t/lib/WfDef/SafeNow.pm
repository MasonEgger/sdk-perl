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

# The :Run draws the activation timestamp via Workflow::time and Workflow::now and
# an RNG value via Workflow::random. None of these may trip the guard with it
# installed (T-det-4). now is the load-bearing case (bug #4, B10): it builds a
# DateTime via DateTime->from_epoch, which calls the `gmtime` builtin the guard
# traps - so now must construct it under the guard-suppression hatch to honor the
# same self-exemption time and random already enjoy, or every live activation that
# calls now task-fails. Returning now->epoch makes the exemption observable.
class WfDef::SafeNow :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $t   = Temporalio::Workflow::time();
        my $now = Temporalio::Workflow::now->epoch;
        my $rng = Temporalio::Workflow::random();
        return { t => $t, now => $now, r => $rng->irand };
    }
}

1;
