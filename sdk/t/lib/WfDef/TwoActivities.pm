# ABOUTME: Fixture workflow that starts two activities concurrently via
# ABOUTME: start_activity and awaits both — drives seq allocation (1 then 2) and
# ABOUTME: out-of-order ResolveActivity resolution in the activities replay test.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts two activities back to back WITHOUT awaiting between them, so
# both ScheduleActivity commands are emitted on the first activation with
# seq 1 and seq 2 respectively. It then awaits both handles and returns the
# pair. A later activation may resolve them in either order; each result must
# land on the correct handle (matched by seq).
class WfDef::TwoActivities :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h1 = Temporalio::Workflow::start_activity(
            'First',
            start_to_close_timeout => 60,
        );
        my $h2 = Temporalio::Workflow::start_activity(
            'Second',
            start_to_close_timeout => 60,
        );
        my $r1 = await $h1;
        my $r2 = await $h2;
        return [ $r1, $r2 ];
    }
}

1;
