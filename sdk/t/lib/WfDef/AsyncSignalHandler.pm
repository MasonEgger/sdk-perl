# ABOUTME: Fixture workflow with an async :Signal handler that awaits a timer
# ABOUTME: before mutating state — drives in-progress-handler tracking and the
# ABOUTME: completion-gating case in signals.t (handler pumped to completion).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run completes as soon as $done flips true. The async :Signal handler
# awaits its OWN timer (emitting a StartTimer) before flipping $done — so on the
# activation that delivers the signal, the handler parks on its timer and the
# workflow is NOT complete (the handler's Future is still in-progress). The
# StartTimer the handler emitted appears in that activation's commands. A later
# FireTimer for the handler's timer resumes the handler, which flips $done; the
# :Run body (re-checked each pump) then returns and the workflow completes.
class WfDef::AsyncSignalHandler :isa(Temporalio::Workflow::Definition) {
    field $done = 0;
    field $value;

    async method run :Run () {
        # Poll-park on a timer until the signal handler has finished. wait_condition
        # lands in P4.3, so the body re-checks $done after each timer tick; the
        # runner re-pumps the body on every activation, so the next FireTimer that
        # resolves the body's own timer re-enters this loop.
        until ($done) {
            await Temporalio::Workflow::sleep(1);
        }
        return $value;
    }

    async method on_signal :Signal('go') ($v) {
        await Temporalio::Workflow::sleep(5);
        $value = $v;
        $done  = 1;
        return;
    }
}

1;
