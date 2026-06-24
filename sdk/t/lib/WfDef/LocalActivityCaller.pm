# ABOUTME: Fixture workflow that calls one local activity via
# ABOUTME: execute_local_activity and returns its result — drives the
# ABOUTME: ScheduleLocalActivity->ResolveActivity round trip (T-local-1/2/5/6/7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run schedules a single LOCAL activity and awaits its result. The first
# activation (InitializeWorkflow) parks the body on the LA's Workflow::Future
# and emits a ScheduleLocalActivity command; a later activation carrying
# ResolveActivity{seq:1} resumes the body, which returns the result. A terminal
# failure surfaces as an exception at the await site (bubbles out of :Run).
class WfDef::LocalActivityCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = 'Alice') {
        my $greeting = await Temporalio::Workflow::execute_local_activity(
            'SayHello',
            args                   => [$name],
            start_to_close_timeout => 60,
        );
        return "got: $greeting";
    }
}

1;
