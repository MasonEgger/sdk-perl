# ABOUTME: Fixture workflow whose :Run awaits wait_condition on a counter
# ABOUTME: reaching a threshold — drives the re-check-each-pump-until-stable
# ABOUTME: path in wait_condition.t (the predicate stays pending across pumps).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run blocks until the counter reaches 2. Each `bump` signal increments it.
# The predicate is re-checked after every activation: a single bump (counter 1)
# leaves the wait pending (no completion); a second bump (counter 2) satisfies
# it and resumes :Run. This proves wait_condition re-checks each pump and does
# NOT resolve until the predicate is stably true.
class WfDef::CounterWaiter :isa(Temporalio::Workflow::Definition) {
    field $count = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $count >= 2 });
        return "count:$count";
    }

    method bump :Signal('bump') () {
        $count++;
        return;
    }
}

1;
