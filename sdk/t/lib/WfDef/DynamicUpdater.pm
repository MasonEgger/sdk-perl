# ABOUTME: Fixture workflow with a dynamic :Update(dynamic=1) catch-all handler,
# ABOUTME: drives the dynamic-dispatch (name, @args) update case (T-upd-9) in
# ABOUTME: updates.t. This fixture registers no validator, so it is accepted
# ABOUTME: unconditionally.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on a long timer. The dynamic :Update handler matches any update
# name with no named handler; it is called as ($name, @args) and returns a
# string echoing the name and first arg. This fixture registers no validator
# via Temporalio::Workflow->set_dynamic_update_handler, so its update is
# accepted unconditionally (a dynamic handler installed WITH a runtime
# validator is exercised in WfDef::DynUpdateValidator instead, I9 / #9).
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
