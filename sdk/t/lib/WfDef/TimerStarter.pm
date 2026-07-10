# ABOUTME: Fixture workflow that starts a timer with start_timer (no await) and
# ABOUTME: returns immediately — proves start_timer emits StartTimer without sleep.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts a timer but does NOT await it, then returns right away. This
# isolates the StartTimer command emission (seq, start_to_fire_timeout) from the
# sleep-await round trip, and proves start_timer returns a Workflow::Future the
# body can choose not to block on.
class WfDef::TimerStarter :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($seconds = 30) {
        Temporalio::Workflow::start_timer($seconds);
        return 'started';
    }
}

1;
