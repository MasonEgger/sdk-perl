# ABOUTME: Fixture workflow that starts two local activities concurrently via
# ABOUTME: start_local_activity and awaits both — drives T-local-4/8 (shared
# ABOUTME: %pending_activities seq space, independent out-of-order resolution).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts two LAs back to back WITHOUT awaiting between them, so both
# ScheduleLocalActivity commands are emitted on the first activation (seq 1 and
# seq 2 from the SAME activity seq space). It then awaits both and returns the
# pair. Each outer future resolves independently (one may complete, one fail).
class WfDef::ConcurrentLocalActivities :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h1 = Temporalio::Workflow::start_local_activity(
            'First',
            start_to_close_timeout => 60,
        );
        my $h2 = Temporalio::Workflow::start_local_activity(
            'Second',
            start_to_close_timeout => 60,
        );
        my $r1 = await $h1;
        my $r2 = await $h2;
        return [ $r1, $r2 ];
    }
}

1;
