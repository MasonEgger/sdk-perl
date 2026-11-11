# ABOUTME: Fixture workflow that re-installs and removes its RUNTIME dynamic
# ABOUTME: update handler on signal, driving the F7 install/uninstall symmetry
# ABOUTME: cases (an omitted validator clears the previous one; removing the
# ABOUTME: handler drops its validator) in dynamic_update_validator.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# The handler and validator are fields so the signal handlers can re-install
# the SAME coderefs the :Run prologue installed; only the pairing changes.
# The validator rejects every update, so "accepted" in a replay test is proof
# the validator is gone rather than proof of a lenient argument.
#
# Signals (each writable, so each may call set_dynamic_update_handler):
#   drop_validator         re-install the handler with NO validator
#   restore                re-install the handler WITH the validator
#   remove_then_reinstall  remove the handler, then install it alone
class WfDef::DynUpdateValidatorReinstall :isa(Temporalio::Workflow::Definition) {
    field $handler;
    field $validator;

    async method run :Run () {
        $handler   = sub ($name, @args) { return "dyn:$name" };
        $validator = sub ($name, @args) {
            Temporalio::Exception::Application->throw(
                message => 'rejected by the reinstall validator',
                type    => 'ReinstallReject',
            );
        };
        Temporalio::Workflow->set_dynamic_update_handler(
            $handler, validator => $validator);
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }

    method drop_validator :Signal('drop_validator') (@) {
        Temporalio::Workflow->set_dynamic_update_handler($handler);
        return;
    }

    method restore :Signal('restore') (@) {
        Temporalio::Workflow->set_dynamic_update_handler(
            $handler, validator => $validator);
        return;
    }

    method remove_then_reinstall :Signal('remove_then_reinstall') (@) {
        Temporalio::Workflow->set_dynamic_update_handler(undef);
        Temporalio::Workflow->set_dynamic_update_handler($handler);
        return;
    }
}

1;
