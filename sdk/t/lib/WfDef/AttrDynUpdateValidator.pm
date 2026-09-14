# ABOUTME: Fixture workflow whose DYNAMIC :Update(dynamic=1) method carries an
# ABOUTME: ATTRIBUTE-declared :UpdateValidator naming that method, alongside a
# ABOUTME: named update with its own validator and a named update with none,
# ABOUTME: driving the F7 attribute-wiring, no-fallback, and runtime-wins
# ABOUTME: precedence cases (I9, #9).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# Three update surfaces on one class, so one fixture pins the whole resolution
# table (spec F7):
#
#   any_update   :Update(dynamic=1)   + :UpdateValidator('any_update')
#     The dynamic catch-all with an attribute validator keyed by the dynamic
#     method's NAME (a dynamic handler has no update name, so the method name
#     is the only key available). sdk-python spells the same pairing
#     @workflow.update(dynamic=True) + @any_update.validator, which reaches
#     _UpdateDefinition.set_validator on the dynamic definition
#     (workflow/_handlers.py:382).
#
#   guarded      :Update('guarded')   + :UpdateValidator('guarded')
#     An ordinary named update with its own validator.
#
#   plain        :Update('plain')     with NO validator
#     Pins the no-fallback rule: a named update that has no validator of its
#     own is NOT validated by the dynamic definition's validator
#     (_workflow_instance.py:2938-2941). Sending 'reject-me' to `plain` must
#     still be accepted.
#
# Both validators reject the sentinel 'reject-me' with a distinct message and
# type so a replay test can tell which one ran from the rejection failure
# alone.
class WfDef::AttrDynUpdateValidator :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }

    method any_update :Update(dynamic=1) ($name, @args) {
        return "dyn:$name=" . ($args[0] // '');
    }

    method validate_any :UpdateValidator('any_update') ($name, @args) {
        if (($args[0] // '') eq 'reject-me') {
            Temporalio::Exception::Application->throw(
                message => 'rejected by the attribute dynamic validator',
                type    => 'AttrDynamicReject',
            );
        }
        return;
    }

    method guarded :Update('guarded') (@args) {
        return 'guarded=' . ($args[0] // '');
    }

    method validate_guarded :UpdateValidator('guarded') (@args) {
        if (($args[0] // '') eq 'reject-me') {
            Temporalio::Exception::Application->throw(
                message => 'rejected by the named attribute validator',
                type    => 'NamedAttrReject',
            );
        }
        return;
    }

    method plain :Update('plain') (@args) {
        return 'plain=' . ($args[0] // '');
    }

    # Spec F7 precedence: the attribute spelling and the runtime spelling
    # write the SAME dynamic slot, so a later runtime install REPLACES the
    # attribute-promoted pairing wholesale rather than merging with it
    # (sdk-python's workflow_set_update_handler builds a fresh
    # _UpdateDefinition, _workflow_instance.py:1428-1447). Installing a
    # handler with NO validator here therefore drops the attribute validator,
    # and the distinct 'runtime:' prefix proves which handler ran.
    method install_runtime_dynamic :Signal('install_runtime_dynamic') (@) {
        Temporalio::Workflow->set_dynamic_update_handler(
            sub ($name, @args) { return "runtime:$name=" . ($args[0] // '') });
        return;
    }
}

1;
