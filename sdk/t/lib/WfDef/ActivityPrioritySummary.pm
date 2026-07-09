# ABOUTME: Fixture workflow for the activity priority/summary parity test
# ABOUTME: (spec R69 / finding A17): mode 'with' starts an activity carrying a
# ABOUTME: priority object and a summary string; mode 'without' starts one with
# ABOUTME: neither, so the test can assert both presence and clean omission on
# ABOUTME: the emitted ScheduleActivity command.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Common::Priority;

# Each mode starts (never awaits) one activity, then returns 'scheduled', so
# the ScheduleActivity command and the workflow completion land in the same
# activation for the test to inspect (the ActivityOptionProbe convention).
class WfDef::ActivityPrioritySummary :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($mode = 'with') {
        if ($mode eq 'with') {
            Temporalio::Workflow::start_activity(
                'SayHello',
                args                   => ['x'],
                start_to_close_timeout => 60,
                priority => Temporalio::Common::Priority->new(
                    priority_key => 1),
                summary => 'the activity summary',
            );
            return 'scheduled';
        }
        if ($mode eq 'without') {
            Temporalio::Workflow::start_activity(
                'SayHello',
                args                   => ['x'],
                start_to_close_timeout => 60,
            );
            return 'scheduled';
        }
        die "WfDef::ActivityPrioritySummary: unknown mode '$mode'";
    }
}

1;
