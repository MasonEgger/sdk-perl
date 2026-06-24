# ABOUTME: Worker-side fixture workflow exercising client update calls end-to-end
# ABOUTME: (spec section 19): a sync :Update with a rejecting validator, a handler
# ABOUTME: that throws, and a :Run that waits for a `done` update to finish.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

# The :Run waits until a `finish` update sets the done flag, then returns the
# running total. `add` increments the total and returns it; its validator
# rejects a negative delta. `boom` throws an ApplicationError post-acceptance.
class WfDef::UpdatableCounter :isa(Temporalio::Workflow::Definition) {
    field $total = 0;
    field $done  = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $done });
        return $total;
    }

    method add :Update('add') ($delta) {
        $total += $delta;
        return $total;
    }

    method validate_add :UpdateValidator('add') ($delta) {
        if ($delta < 0) {
            Temporalio::Exception::Application->throw(
                message => 'delta must be non-negative',
                type    => 'BadDelta',
            );
        }
        return;
    }

    method boom :Update('boom') (@) {
        Temporalio::Exception::Application->throw(
            message => 'handler boom',
            type    => 'HandlerBoom',
        );
    }

    method finish :Update('finish') (@) {
        $done = 1;
        return 'finishing';
    }
}

1;
