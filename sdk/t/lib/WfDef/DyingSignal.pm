# ABOUTME: Fixture workflow whose synchronous :Signal handler dies — drives
# ABOUTME: the sync-signal die-to-failed-completion funnel case (I2, spec §I2)
# ABOUTME: in signal_handler_die.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks forever on a wait_condition whose flag is never set: the
# signal delivered to the dying handler is what drives the activation under
# test, not any state the body itself advances. The synchronous :Signal
# handler dies immediately (no await), reproducing the bug (spec §I2,
# Runner.pm:3164 _dispatch_signal): a die from an already-ready Future->call
# result was never tracked in %in_progress_handlers and never observed, so
# the activation produced a normal (no-op) completion instead of a failed
# workflow task. sdk-python fails the workflow task the same way a raising
# signal handler does (_workflow_instance.py:2563-2565
# _run_top_level_workflow_function: a non-Temporal-failure exception sets
# self._current_activation_error, the workflow-TASK-failure route). A
# Temporal-failure-typed throw instead fails the workflow EXECUTION — see
# WfDef::DyingSignalFailure for that arm.
class WfDef::DyingSignal :isa(Temporalio::Workflow::Definition) {
    field $never = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $never });
        return 'unreachable';
    }

    method boom :Signal('boom') () {
        die "boom in sync signal\n";
    }
}

1;
