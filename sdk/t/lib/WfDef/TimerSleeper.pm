# ABOUTME: Fixture workflow that sleeps via Temporalio::Workflow::sleep and then
# ABOUTME: returns — drives the StartTimer -> FireTimer round trip in timers.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run sleeps for a fixed duration and then completes. The first activation
# (InitializeWorkflow) parks the body on the timer's Workflow::Future and emits
# a StartTimer command; a later activation carrying FireTimer{seq:1} resumes the
# body, which returns. `sleep` is the documented alias over `start_timer`.
class WfDef::TimerSleeper :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($seconds = 60) {
        await Temporalio::Workflow::sleep($seconds);
        return 'slept';
    }
}

1;
