# ABOUTME: Fixture workflow that calls one activity via execute_activity and
# ABOUTME: returns its result — drives the schedule->resolve round trip in the
# ABOUTME: activities replay test (T-wf-1/2/7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run schedules a single activity and awaits its result. The first
# activation (InitializeWorkflow) parks the body on the activity's
# Workflow::Future and emits a ScheduleActivity command; a later activation
# carrying ResolveActivity{seq:1} resumes the body, which returns the result.
# An activity failure surfaces as an exception at the await site, which escapes
# :Run (the full outcome table is P3.7; this fixture just lets it bubble).
class WfDef::ActivityCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = 'Alice') {
        my $greeting = await Temporalio::Workflow::execute_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
        );
        return "got: $greeting";
    }
}

1;
