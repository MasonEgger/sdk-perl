# ABOUTME: Fixture workflow whose async :Signal handler awaits then dies.
# ABOUTME: Drives the async-signal coverage case (I2, spec §I2) in
# ABOUTME: signal_handler_die.t, proving the tracked (in_progress_handlers)
# ABOUTME: arm also fails the workflow task.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Same :Run shape as WfDef::DyingSignal (parks forever on an unmet
# wait_condition). The :Signal handler is async: it awaits its own timer
# before dying, so its Future is NOT ready when _dispatch_signal returns and
# is tracked in %in_progress_handlers exactly like a long-running async
# handler. Its later failure must reach the same die-to-failed-completion
# funnel as the sync arm (spec §I2).
class WfDef::DyingAsyncSignal :isa(Temporalio::Workflow::Definition) {
    field $never = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $never });
        return 'unreachable';
    }

    async method boom :Signal('boom') () {
        await Temporalio::Workflow::sleep(1);
        die "boom in async signal\n";
    }
}

1;
