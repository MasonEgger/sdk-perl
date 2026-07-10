# ABOUTME: Regression repro for B2 C-CANCEL-CMD bug #7: a Future->wait_any
# ABOUTME: timer-vs-activity race. On the timer-wins path the run must emit
# ABOUTME: EXACTLY ONE CompleteWorkflowExecution and no RequestCancel for an
# ABOUTME: already-resolved seq. The runner had no "terminal command already
# ABOUTME: emitted" guard, so the cancelled activity's post-completion
# ABOUTME: ResolveActivity re-ran the outcome table and double-completed (which
# ABOUTME: SEGVs the live worker).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Workflow;
use Temporalio::Converter::Payload;

no warnings 'experimental::class';

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# #7 (timer-wins): wait_any(activity, timer); the timer fires first.
#
# Init schedules the DoWork activity (activity seq 1) and arms the race timer
# (timer seq 1), then parks on Future->wait_any. The timer fires first, so
# wait_any cancels the loser (the still-pending activity): one
# RequestCancelActivity(1), and the body returns 'timed-out', one
# CompleteWorkflowExecution. Core THEN delivers the cancelled activity's
# ResolveActivity (seq 1).
#
# Under bug #7 that post-completion activation re-ran the outcome table (the
# :Run Future was still ready+done) and emitted a SECOND
# CompleteWorkflowExecution, the double-complete that SEGVs the live worker.
# This replay asserts on the EMITTED COMMAND LIST (deterministic, no live
# worker), so it surfaces the double-complete without crashing.
# ---------------------------------------------------------------------------
T2->subtest('wait_any timer-wins: one Complete, no RequestCancel for a resolved seq (#7)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::WaitAnyRace',
    );

    my @all;   # every command emitted across the whole run.

    my @a1 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'WaitAnyRace' } },
        ],
    }));
    push @all, @a1;
    my ($sa)  = grep { $_->which_variant eq 'schedule_activity' } @a1;
    my ($st)  = grep { $_->which_variant eq 'start_timer' } @a1;
    T2->ok($sa, 'init schedules the DoWork activity (seq 1)');
    T2->ok($st, 'init arms the race timer (seq 1)');
    T2->is($sa->schedule_activity->seq, 1, 'activity seq is 1');
    T2->is($st->start_timer->seq, 1, 'timer seq is 1');

    # Timer wins: FireTimer for the race timer. wait_any cancels the loser
    # activity and the body returns 'timed-out'.
    my @a2 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 6 },
        jobs      => [ { fire_timer => { seq => 1 } } ],
    }));
    push @all, @a2;
    my ($rca) = grep { $_->which_variant eq 'request_cancel_activity' } @a2;
    T2->ok($rca, 'timer-wins cancels the loser activity (RequestCancelActivity)');
    T2->is($rca->request_cancel_activity->seq, 1,
        'the loser RequestCancelActivity targets the activity seq (1)');

    # Post-completion activation: core delivers the cancelled activity's
    # ResolveActivity (seq 1, already cancelled). This is where the duplicate
    # CompleteWorkflowExecution appeared under the bug.
    my @a3 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 7 },
        jobs      => [
            { resolve_activity => {
                seq    => 1,
                result => { cancelled => { failure => { message => 'cancelled' } } },
            } },
        ],
    }));
    push @all, @a3;

    # The crux: across the WHOLE run, exactly one CompleteWorkflowExecution.
    # Under bug #7 there were TWO Completes (the double-complete).
    my @completes = grep { $_->which_variant eq 'complete_workflow_execution' } @all;
    T2->is(scalar @completes, 1,
        'exactly one CompleteWorkflowExecution across the run (no double-complete, #7)');
    T2->is(
        $PC->from_payload($completes[0]->complete_workflow_execution->result),
        'timed-out',
        'the single completion carries the timer-wins result');

    # And no RequestCancel is emitted for the activity seq AFTER it resolved:
    # the seq-1 ResolveActivity in a3 must not provoke a fresh
    # RequestCancelActivity (the cancel was already issued in a2).
    my @reqcancels_a3 = grep { $_->which_variant eq 'request_cancel_activity' } @a3;
    T2->is(scalar @reqcancels_a3, 0,
        'no RequestCancel for an already-resolved seq on the post-completion activation');
    my @all_reqcancels = grep { $_->which_variant eq 'request_cancel_activity' } @all;
    T2->is(scalar @all_reqcancels, 1,
        'exactly one RequestCancelActivity across the run (the loser cancel)');
});

T2->done_testing;
