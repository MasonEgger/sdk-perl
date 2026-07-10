# ABOUTME: Fixture workflow with a dynamic :Update(dynamic=1) catch-all handler —
# ABOUTME: drives the dynamic-dispatch (name, @args) update case (T-upd-9) in
# ABOUTME: updates.t. The dynamic handler is never validated.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on a long timer. The dynamic :Update handler matches any update
# name with no named handler; it is called as ($name, @args) and returns a
# string echoing the name and first arg. A dynamic handler is never run through
# a validator (there is no dynamic validator).
class WfDef::DynamicUpdater :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }

    method any_update :Update(dynamic=1) ($name, @args) {
        return "$name=$args[0]";
    }
}

1;
