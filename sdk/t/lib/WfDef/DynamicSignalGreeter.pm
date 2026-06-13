# ABOUTME: Fixture workflow with a dynamic catch-all :Signal handler — drives the
# ABOUTME: dynamic-handler fallback case (an unmatched signal name routes to the
# ABOUTME: dynamic handler) in signals.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# No named signal handlers; a single dynamic catch-all (:Signal(dynamic=1))
# receives every signal as (name, args). The :Run sleeps so the body parks and
# the dynamic-handled signal's effect is visible when the timer fires.
class WfDef::DynamicSignalGreeter :isa(Temporalio::Workflow::Definition) {
    field @log;

    async method run :Run () {
        await Temporalio::Workflow::sleep(60);
        return join(',', @log);
    }

    method any_signal :Signal(dynamic=1) ($name, @args) {
        push @log, "$name=" . join('+', @args);
        return;
    }
}

1;
