# ABOUTME: Fixture workflow that runs three local activities serially —
# ABOUTME: drives T-local-3 (three ScheduleLocalActivity commands, one per
# ABOUTME: activation as each resolves before the next is scheduled).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run awaits each LA before scheduling the next, so each activation emits
# exactly one ScheduleLocalActivity (seq 1, then 2, then 3). Returns the joined
# results.
class WfDef::ThreeLocalActivities :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my @out;
        for my $type (qw(First Second Third)) {
            push @out, await Temporalio::Workflow::execute_local_activity(
                $type,
                start_to_close_timeout => 60,
            );
        }
        return join ',', @out;
    }
}

1;
