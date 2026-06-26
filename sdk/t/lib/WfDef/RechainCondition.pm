# ABOUTME: Fixture for bug #3 (B1 C-COND): a :Run that, on waking from its first
# ABOUTME: wait_condition, SYNCHRONOUSLY re-parks on a second wait_condition during
# ABOUTME: the same _check_conditions pass — exercising the re-registration drop.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on $phase1. A `flip1` signal sets $phase1 true; the pump's
# _check_conditions resolves that wait and runs the :Run continuation
# SYNCHRONOUSLY, which immediately awaits a SECOND wait_condition on $phase2
# (still false). That second condition is registered DURING the same
# _check_conditions pass. A later `flip2` signal must wake it and let the body
# return — bug #3 dropped this re-registered condition (`@conditions = @still`),
# so flip2 never woke the body and the workflow wedged Running.
class WfDef::RechainCondition :isa(Temporalio::Workflow::Definition) {
    field $phase1 = 0;
    field $phase2 = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $phase1 });
        await Temporalio::Workflow::wait_condition(sub { $phase2 });
        return 'both';
    }

    method flip1 :Signal('flip1') (@) { $phase1 = 1; return; }
    method flip2 :Signal('flip2') (@) { $phase2 = 1; return; }
}

1;
