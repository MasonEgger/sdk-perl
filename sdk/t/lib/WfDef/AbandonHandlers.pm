# ABOUTME: Fixture workflow whose :Run returns immediately while async :Update
# ABOUTME: and :Signal handlers declared with unfinished_policy=ABANDON are
# ABOUTME: still in-flight — drives the no-warning half of R87.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run returns immediately. Both handlers are async and park on an
# activity, so when :Run returns their Futures are still pending. Each is
# declared with unfinished_policy=ABANDON (spec R87; parity audit, in-workflow
# finding 5), the opt-out that suppresses the unfinished-handler completion
# warning — Python's @workflow.update(unfinished_policy=HandlerUnfinishedPolicy.ABANDON)
# (_handlers.py:36).
class WfDef::AbandonHandlers :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        return 'run-done';
    }

    async method slow_update :Update('slowUpdate', 'unfinished_policy=ABANDON') ($name) {
        my $greeting = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
        );
        return "got: $greeting";
    }

    async method slow_signal :Signal('slowSignal', 'unfinished_policy=ABANDON') ($name) {
        await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
        );
        return;
    }
}

1;
