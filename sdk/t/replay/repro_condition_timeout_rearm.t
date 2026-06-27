# ABOUTME: Regression repro for B10 C-COND-TIMEOUT (bug #4): a wait_condition WITH A
# ABOUTME: TIMEOUT whose backing durable timer is cancelled and re-armed against a MOVED
# ABOUTME: deadline (the updatable-timer pattern). B1's plain re-park fix is present but does
# ABOUTME: NOT cover this distinct timeout-timer cancel/re-arm path: arm a long timer, an
# ABOUTME: :Update moves the deadline earlier, re-arm a short timer. Today the stale long
# ABOUTME: timer is not cleanly cancelled before the new one arms and the body wedges Running.
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
# #4 (B10, the timeout-timer cancel/re-arm path, DISTINCT from B1's #4 re-park):
#
# The :Run parks on wait_condition(sub { $updated }, timeout => remaining), where
# remaining is recomputed from the LIVE deadline each loop iteration. At init the
# deadline is far out, so a LONG timer is armed. A `move` :Update pulls the deadline
# EARLIER and flips $updated; _check_conditions resolves the wait, must CANCEL the
# stale long timer (CancelTimer), and the continuation re-arms a SHORT timer for the
# new remaining. When the short timer fires the wait raises Timeout, the loop sees
# should_wake true and the body returns.
#
# Under bug #4 the stale long timer is not cleanly torn down before the short timer
# arms: the re-armed condition is left parked forever (the FireTimer for the short
# timer never re-evaluates the loop), so the workflow wedges Running: the final
# activation emits the update response but NO complete_workflow_execution.
# ---------------------------------------------------------------------------
T2->subtest('wait_condition timeout timer is cancelled and re-armed on a moved deadline (#4)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::DeadlineMover',
    );

    # init at t=100, wake deadline at epoch 300 => remaining 200s (the LONG timer).
    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'DeadlineMover',
                arguments     => [ payload(300) ],
            } },
        ],
    }));
    my @init_timers = grep { $_->which_variant eq 'start_timer' } @init;
    T2->is(scalar @init_timers, 1, 'init arms exactly one (long) timer');
    T2->is($init_timers[0]->start_timer->seq, 1, 'long timer is seq 1');
    T2->is($init_timers[0]->start_timer->start_to_fire_timeout->seconds, 200,
        'the armed timer is the long (200s) remaining timer');

    # move at t=150: pull the deadline to epoch 160 => new remaining 10s. This must
    # cancel the stale long timer (seq 1) and re-arm a short timer (seq 2, 10s).
    my @after_move = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 150 },
        jobs      => [
            { do_update => {
                id                   => 'u-move',
                protocol_instance_id => 'pi-move',
                name                 => 'move',
                input                => [ payload(160) ],
                run_validator        => 1,
            } },
        ],
    }));

    my @cancels = grep { $_->which_variant eq 'cancel_timer' } @after_move;
    T2->is(scalar @cancels, 1, 'move cancels exactly the stale long timer');
    T2->is($cancels[0]->cancel_timer->seq, 1, 'the cancelled timer is the long timer (seq 1)');

    my @rearm_timers = grep { $_->which_variant eq 'start_timer' } @after_move;
    T2->is(scalar @rearm_timers, 1, 'move re-arms exactly one fresh (short) timer');
    T2->is($rearm_timers[0]->start_timer->seq, 2, 're-armed timer is seq 2');
    T2->is($rearm_timers[0]->start_timer->start_to_fire_timeout->seconds, 10,
        'the re-armed timer is the short (10s) moved-deadline timer');
    T2->ok(!(grep { $_->which_variant eq 'complete_workflow_execution' } @after_move),
        'the body has not completed yet (parked on the re-armed short timer)');

    # the short timer (seq 2) fires at t=160: the wait raises Timeout, should_wake is
    # now true, and the body returns.
    my @after_fire = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 160 },
        jobs      => [
            { fire_timer => { seq => 2 } },
        ],
    }));

    my @complete = grep { $_->which_variant eq 'complete_workflow_execution' } @after_fire;
    T2->is(scalar @complete, 1,
        'the re-armed short timer drives the loop to exit and the body completes (no wedge)');
    T2->is(
        $PC->from_payload($complete[0]->complete_workflow_execution->result),
        160,
        'the resumed :Run woke at the moved deadline (t=160), not the original far one');
});

T2->done_testing;
