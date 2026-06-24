# ABOUTME: Fixture workflow whose :Run returns immediately while an async
# ABOUTME: :Update handler is still in-flight — drives the warn-and-complete
# ABOUTME: completion gating case (M1) in updates.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run returns immediately. The slowUpdate handler is async and parks on an
# activity, so when :Run returns the handler Future is still pending. The runner
# warns about the unfinished handler and completes the workflow anyway (parity
# with sdk-python/sdk-ruby warn-and-complete) rather than hard-blocking.
class WfDef::ReturningUpdater :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        return 'run-done';
    }

    async method slow_update :Update('slowUpdate') ($name) {
        my $greeting = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
        );
        return "got: $greeting";
    }
}

1;
