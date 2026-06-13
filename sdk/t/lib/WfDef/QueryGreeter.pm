# ABOUTME: Fixture workflow with :Query handlers (and a :Signal that mutates the
# ABOUTME: queried state) — drives query dispatch, the dying-handler failure
# ABOUTME: case, and the queries-last ordering case (T-wf-4) in queries.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on a long timer so the body never completes during the query
# tests — a query observes the in-flight workflow's state without disturbing the
# run Future (T-wf-4). A :Signal mutates the greeting; the queries-last ordering
# means a query delivered in the SAME activation as a signal observes the
# post-signal state. The "boom" query always throws, exercising the
# dying-handler -> query failure path (NOT a workflow/task failure).
class WfDef::QueryGreeter :isa(Temporalio::Workflow::Definition) {
    field $greeting = 'initial';

    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return $greeting;
    }

    method set_greeting :Signal('set') ($value) {
        $greeting = $value;
        return;
    }

    method current :Query('greeting') () {
        return $greeting;
    }

    method boom :Query('boom') () {
        die "query handler exploded\n";
    }
}

1;
