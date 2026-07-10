# ABOUTME: Fixture workflow for the timer summary parity test (spec R78 /
# ABOUTME: in-workflow finding 2): modes start a timer via sleep, start_timer,
# ABOUTME: or a wait_condition timeout, carrying a summary/timeout_summary (or
# ABOUTME: none), so the test can assert both presence and clean omission of
# ABOUTME: user_metadata.summary on the emitted StartTimer command.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Each mode STARTS (never awaits) its timer, then returns 'scheduled', so the
# StartTimer command and the workflow completion land in the same activation
# for the test to inspect (the ActivityPrioritySummary convention).
class WfDef::TimerSummary :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($mode = 'sleep_with') {
        if ($mode eq 'sleep_with') {
            Temporalio::Workflow::sleep(5, summary => 'the sleep summary');
            return 'scheduled';
        }
        if ($mode eq 'timer_with') {
            Temporalio::Workflow::start_timer(
                7, summary => 'the timer summary');
            return 'scheduled';
        }
        if ($mode eq 'condition_with') {
            Temporalio::Workflow::wait_condition(
                sub { 0 },
                timeout         => 30,
                timeout_summary => 'the timeout summary',
            );
            return 'scheduled';
        }
        if ($mode eq 'without') {
            Temporalio::Workflow::sleep(5);
            Temporalio::Workflow::start_timer(7);
            return 'scheduled';
        }
        die "WfDef::TimerSummary: unknown mode '$mode'";
    }
}

1;
