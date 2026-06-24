# ABOUTME: Fixture workflow whose :UpdateValidator issues a workflow command
# ABOUTME: (illegal — validators are read-only) — drives the validator-command
# ABOUTME: workflow-task-failure case (T-upd-10) in updates.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The validator for `cmd` violates the read-only contract by starting a timer
# (a command). Under the runner's read-only guard this throws, and the
# violation is a WORKFLOW TASK failure (not an update rejection).
class WfDef::MutatingValidator :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return 'ok';
    }

    method cmd :Update('cmd') ($) {
        return 'never reached';
    }

    method validate_cmd :UpdateValidator('cmd') ($) {
        # Illegal: a validator must not issue commands. start_timer emits a
        # StartTimer command, which the read-only guard rejects.
        Temporalio::Workflow::start_timer(1);
        return;
    }
}

1;
