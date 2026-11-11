# ABOUTME: Fixture workflow whose DYNAMIC update validator issues a workflow
# ABOUTME: command (illegal; validators are read-only), drives the
# ABOUTME: dynamic-validator read-only-guard case (I9, closes #9) in
# ABOUTME: dynamic_update_validator.t, matching WfDef::MutatingValidator's
# ABOUTME: named-validator equivalent.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run installs the dynamic handler and validator up front, then parks on
# a timer. The dynamic validator violates the read-only contract by starting a
# timer (a command). Under the runner's read-only guard this is a WORKFLOW
# TASK failure, not an update rejection, identical to the named-validator
# violation in WfDef::MutatingValidator.
class WfDef::DynUpdateValidatorViolation :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        Temporalio::Workflow->set_dynamic_update_handler(
            sub ($name, @args) {
                return 'never reached';
            },
            validator => sub (@args) {
                Temporalio::Workflow::start_timer(1);
                return;
            },
        );
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }
}

1;
