# ABOUTME: Fixture workflow whose :Run returns immediately while an async
# ABOUTME: :Signal handler with the DEFAULT unfinished policy is still
# ABOUTME: in-flight — drives the default-still-warns signal case of R87.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run returns immediately. slowSignal is async and parks on an activity,
# so when :Run returns the handler Future is still pending. No
# unfinished_policy is declared, so the default WARN_AND_ABANDON applies
# (spec R87; Python _handlers.py:36) and the runner warns at completion.
class WfDef::ReturningSignaler :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        return 'run-done';
    }

    async method slow_signal :Signal('slowSignal') ($name) {
        await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
        );
        return;
    }
}

1;
