# ABOUTME: Fixture workflow whose synchronous :Signal handler throws a
# ABOUTME: Temporalio::Exception::Application, driving the FailWorkflowExecution
# ABOUTME: classification arm (spec §I2 correction, GitHub issue #2 follow-up)
# ABOUTME: in signal_handler_die.t, alongside WfDef::DyingSignal's plain-die
# ABOUTME: task-failure arm.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# Same :Run shape as WfDef::DyingSignal (parks forever on an unmet
# wait_condition): the signal delivered to the dying handler drives the
# activation under test. The synchronous :Signal handler throws a Temporal
# failure-type exception (Application), which fails the workflow EXECUTION
# (FailWorkflowExecution), not the workflow task, unlike WfDef::DyingSignal's
# plain die. MUST-match sdk-python
# (worker/_workflow_instance.py:2560-2562 _run_top_level_workflow_function:
# workflow_is_failure_exception -> _set_workflow_failure).
class WfDef::DyingSignalFailure :isa(Temporalio::Workflow::Definition) {
    field $never = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $never });
        return 'unreachable';
    }

    method boom :Signal('boom') () {
        Temporalio::Exception::Application->throw(
            message => 'app boom in sync signal',
            type    => 'BoomError',
        );
    }
}

1;
