# ABOUTME: Fixture workflow with an async :Update handler that awaits an activity
# ABOUTME: before returning — drives the accept-then-complete-across-activations
# ABOUTME: update case (T-upd-4) in updates.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on a long timer so the workflow stays open. The `slowUpdate`
# handler is async: on the activation that delivers the DoUpdate it emits the
# UpdateResponse.accepted AND schedules an activity, then parks. The workflow is
# NOT complete while the handler Future is in-flight. A later activation that
# resolves the activity resumes the handler, which returns — emitting the
# UpdateResponse.completed.
class WfDef::AsyncUpdater :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        await Temporalio::Workflow::sleep(3600);
        return 'done';
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
