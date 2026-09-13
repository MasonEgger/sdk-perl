# ABOUTME: Fixture workflow that installs a DYNAMIC update handler AND a
# ABOUTME: paired validator at runtime via
# ABOUTME: Temporalio::Workflow->set_dynamic_update_handler, drives the
# ABOUTME: dynamic-validator wiring (I9, closes #9) in dynamic_update_validator.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# The :Run installs the dynamic handler and its validator up front, then parks
# on a timer. The validator rejects any update whose first argument is the
# sentinel 'reject-me' by throwing a Temporal failure (a single
# UpdateResponse.rejected, no acceptance); anything else is admitted. The
# validator also records the (name, args) it was called with into
# $validator_saw, and the dynamic handler folds that into its return value, so
# a replay test can assert the validator received the exact same
# (name, @args) list the handler did (spec R86 parity with sdk-python
# _workflow_instance.py:2400-2414).
class WfDef::DynUpdateValidator :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $validator_saw = '';
        Temporalio::Workflow->set_dynamic_update_handler(
            sub ($name, @args) {
                return "$name=$args[0]|validator_saw=$validator_saw";
            },
            validator => sub ($name, @args) {
                $validator_saw = "$name=" . ($args[0] // '');
                if (($args[0] // '') eq 'reject-me') {
                    Temporalio::Exception::Application->throw(
                        message => 'rejected by dynamic validator',
                        type    => 'DynamicReject',
                    );
                }
                return;
            },
        );
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }
}

1;
