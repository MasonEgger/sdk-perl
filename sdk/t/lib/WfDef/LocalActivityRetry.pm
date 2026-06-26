# ABOUTME: Fixture workflow (B5 #9) that runs one local activity with an explicit
# ABOUTME: start_to_close_timeout AND a retry_policy, so the activity fails its
# ABOUTME: first attempt and succeeds on retry — exercising the local-activity
# ABOUTME: backoff/re-schedule loop end to end against a live server.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Common::RetryPolicy ();

# The :Run schedules a single LOCAL activity that is flaky (fails attempt 1,
# succeeds attempt 2). A retry_policy with maximum_attempts > 1 and a small
# initial_interval drives the ScheduleLocalActivity -> ResolveActivity(DoBackoff)
# -> re-schedule loop. The activity's eventual result bubbles back as the result.
class WfDef::LocalActivityRetry :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = 'Bob') {
        my $greeting = await Temporalio::Workflow::execute_local_activity(
            'FlakySayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
            retry_policy           => Temporalio::Common::RetryPolicy->new(
                initial_interval => 0.1,
                maximum_attempts => 3,
            ),
        );
        return "got: $greeting";
    }
}

1;
