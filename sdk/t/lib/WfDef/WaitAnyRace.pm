# ABOUTME: Replay fixture for B2 bug #7: a timer-vs-activity race built with the
# ABOUTME: natural Future->wait_any (NOT the on_ready/leave-the-loser-pending
# ABOUTME: workaround). wait_any cancels the loser; on the timer-wins path the
# ABOUTME: activity is cancelled and the body completes, then core resolves the
# ABOUTME: cancelled activity, which must not trigger a second completion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future;
use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Mirrors the timer sample's RaceTimer (Timer::Workflow) but uses the natural
# Future->wait_any combinator instead of the hand-rolled on_ready race the
# sample adopted for bug #7. The body starts the DoWork activity and a durable
# timer, then awaits whichever settles first. wait_any cancels the loser: on the
# timer-wins path the still-pending activity is cancelled (one
# RequestCancelActivity) and the body returns 'timed-out' (one
# CompleteWorkflowExecution). Core afterwards delivers the cancelled activity's
# ResolveActivity, and the runner must NOT re-emit a second
# CompleteWorkflowExecution on that post-terminal activation.
class WfDef::WaitAnyRace :isa(Temporalio::Workflow::Definition) {
    async method run :Run('WaitAnyRace') ( $timeout_seconds = 5, $work_seconds = 1 ) {
        my $activity_future = Temporalio::Workflow::start_activity(
            'DoWork',
            args                   => [$work_seconds],
            start_to_close_timeout => 60,
        );
        my $timer_future = Temporalio::Workflow::start_timer($timeout_seconds);

        await Future->wait_any( $activity_future, $timer_future );

        # The activity wins only if its Future is DONE (real work finished). On
        # the timer-wins path wait_any cancelled the activity, so it is ready but
        # NOT done, and the timeout result wins. (Matches the sample's pure
        # Timer::Race::resolve_race decision.)
        return $activity_future->is_done ? 'work-done' : 'timed-out';
    }
}

1;
