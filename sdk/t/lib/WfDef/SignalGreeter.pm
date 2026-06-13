# ABOUTME: Fixture workflow whose :Signal handlers mutate state the :Run body
# ABOUTME: reads after a timer — drives signal dispatch, ordering, and the
# ABOUTME: before-:Run-returns visibility case (T-wf-3) in signals.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run sleeps on a timer (parking the body) and then returns the greeting
# accumulated by signals. A SignalWorkflow job delivered in the same activation
# as InitializeWorkflow is processed BEFORE the run continuation observes the
# field (T-wf-3: signal semantically processed first, mutation visible to the
# :Run continuation when the timer fires). A second :Signal appends; signals are
# delivered in order, so the field reflects every signal in arrival order.
class WfDef::SignalGreeter :isa(Temporalio::Workflow::Definition) {
    field @parts;

    async method run :Run () {
        await Temporalio::Workflow::sleep(60);
        return join(',', @parts);
    }

    method add :Signal('add') ($value) {
        push @parts, $value;
        return;
    }

    method set_prefix :Signal('setPrefix') ($value) {
        unshift @parts, "prefix:$value";
        return;
    }
}

1;
