# ABOUTME: Eager-activity fixture workflow (P7.3 / spec section 23.2): schedules
# ABOUTME: one activity with a short schedule_to_start timeout so a worker with
# ABOUTME: no_remote_activities lets it time out SCHEDULE_TO_START.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Schedules SayHello with a 2s schedule_to_start timeout. On a worker that has
# disabled remote activities, no poller picks the task off the queue, so the
# activity fails SCHEDULE_TO_START and the failure propagates to :Run.
class WfDef::EagerActivityWorkflow :isa(Temporalio::Workflow::Definition) {
    async method run :Run('EagerActivityWorkflow') ($name = 'World') {
        my $greeting = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                      => [$name],
            schedule_to_start_timeout => 2,
            start_to_close_timeout    => 30,
        );
        return $greeting;
    }
}

1;
