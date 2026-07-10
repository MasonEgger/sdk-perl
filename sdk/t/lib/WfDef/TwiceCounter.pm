# ABOUTME: Replay target workflow (t/replay/repro_external_signal.t) — counts inbound 'tick' signals and waits
# ABOUTME: until it has seen two, then returns the count. Pairs with
# ABOUTME: WfDef::TwiceSignaller to guard cross-workflow signal hand-off (#2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Waits for two 'tick' signals (sent by TwiceSignaller through an
# ExternalWorkflowHandle), then returns the observed count. A :Query exposes the
# running count so a test can poll progress without racing the result.
class WfDef::TwiceCounter :isa(Temporalio::Workflow::Definition) {
    field $count = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $count >= 2 });
        return $count;
    }

    method on_tick :Signal('tick') ($n = 0) {
        $count++;
        return;
    }

    method tick_count :Query('tick_count') () {
        return $count;
    }
}

1;
