# ABOUTME: Fixture workflow with a sync :Update handler and a paired validator —
# ABOUTME: drives the accepted/validator-rejected/no-validator update cases
# ABOUTME: (T-upd-1/2/3) in updates.t. The :Run parks on a long timer.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# The :Run sleeps on a timer (parking the body) and then returns the running
# total. The `add` :Update handler mutates state and returns the new total
# (the value the UpdateResponse.completed carries). Its validator rejects a
# negative delta by throwing — a synchronous, read-only check. `addNoValidator`
# has no validator, so it is accepted unconditionally.
class WfDef::UpdateCounter :isa(Temporalio::Workflow::Definition) {
    field $total = 0;

    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return $total;
    }

    method add :Update('add') ($delta) {
        $total += $delta;
        return $total;
    }

    # The validator must be synchronous and read-only: it inspects the argument
    # and throws to reject. A non-mutating check.
    method validate_add :UpdateValidator('add') ($delta) {
        if ($delta < 0) {
            Temporalio::Exception::Application->throw(
                message => 'delta must be non-negative',
                type    => 'BadDelta',
            );
        }
        return;
    }

    method add_no_validator :Update('addNoValidator') ($delta) {
        $total += $delta;
        return $total;
    }
}

1;
