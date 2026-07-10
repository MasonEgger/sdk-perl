# ABOUTME: Regression repros for B1 C-COND (bugs #3 and #4): a wait_condition
# ABOUTME: registered SYNCHRONOUSLY by a continuation running inside the same
# ABOUTME: _check_conditions pass must survive the pending-list rebuild and be
# ABOUTME: re-evaluated. Runner.pm's old `@conditions = @still` clobbered it,
# ABOUTME: wedging the body Running forever (batch-sliding-window / updatable-timer).
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
# #3: a continuation that re-parks synchronously during _check_conditions.
#
# The :Run parks on phase1. The `flip1` signal flips phase1 true; the pump's
# _check_conditions resolves that wait and runs the :Run continuation
# synchronously, which awaits a SECOND wait_condition on phase2 (still false) —
# registered DURING the same _check_conditions pass. A later `flip2` signal
# must wake that re-registered condition and let the body return 'both'.
#
# Under bug #3 the rebuild `@conditions = @still` dropped the second condition,
# so flip2 found an empty condition list and the workflow wedged Running: the
# flip2 activation emitted ZERO commands instead of completing.
# ---------------------------------------------------------------------------
T2->subtest('continuation-registered wait_condition survives the pass (#3)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::RechainCondition',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'RechainCondition',
                arguments     => [],
            } },
        ],
    }));
    T2->is(scalar @init, 0, 'init parks on the first condition (no command)');

    my @after_flip1 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [
            { signal_workflow => { signal_name => 'flip1', input => [] } },
        ],
    }));
    T2->is(scalar @after_flip1, 0,
        'flip1 wakes the first wait and re-parks on the second (no command)');

    my @after_flip2 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 120 },
        jobs      => [
            { signal_workflow => { signal_name => 'flip2', input => [] } },
        ],
    }));

    # The crux: with the re-registered condition preserved, flip2 wakes it and
    # the body completes. With the drop bug this list is empty here -> 0 cmds.
    T2->is(scalar @after_flip2, 1,
        'flip2 wakes the re-registered condition and the body completes');
    T2->is($after_flip2[0]->which_variant, 'complete_workflow_execution',
        'the workflow completes once the re-parked condition is satisfied');
    T2->is(
        $PC->from_payload($after_flip2[0]->complete_workflow_execution->result),
        'both',
        'the resumed :Run ran past both wait_conditions');
});

# ---------------------------------------------------------------------------
# #4 (same family): the timer re-arm wedge.
#
# The :Run arms a LONG (100s) timer on its first wait_condition and parks. A
# `wake` :Update flips the first predicate; _check_conditions resolves the wait,
# cancels the long timer, and runs the continuation synchronously, which re-arms
# a SHORT (5s) timer on a fresh wait_condition over the second predicate. A later
# `advance` :Update must wake that re-armed condition and let the body return.
#
# Under bug #4 (same `@conditions = @still` drop) the re-armed condition was
# lost, so `advance` could not wake the body: the activation emitted the update
# responses but NO complete_workflow_execution — the wedge.
# ---------------------------------------------------------------------------
T2->subtest('re-armed wait_condition timer is honored, no wedge (#4)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerRearm',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TimerRearm',
                arguments     => [],
            } },
        ],
    }));
    my @init_timers = grep { $_->which_variant eq 'start_timer' } @init;
    T2->is(scalar @init_timers, 1, 'init arms the long timer');
    T2->is($init_timers[0]->start_timer->start_to_fire_timeout->seconds, 100,
        'the armed timer is the long (100s) timer');

    my @after_wake = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 110 },
        jobs      => [
            { do_update => {
                id                   => 'u-wake',
                protocol_instance_id => 'pi-wake',
                name                 => 'wake',
                input                => [],
                run_validator        => 1,
            } },
        ],
    }));
    # The wake update resolves the first wait, cancels the long timer, and the
    # continuation re-arms the short timer on a fresh wait_condition.
    my @rearm_timers = grep { $_->which_variant eq 'start_timer' } @after_wake;
    T2->is(scalar @rearm_timers, 1, 'wake re-arms a fresh (short) timer');
    T2->is($rearm_timers[0]->start_timer->start_to_fire_timeout->seconds, 5,
        'the re-armed timer is the short (5s) timer');
    T2->ok(!(grep { $_->which_variant eq 'complete_workflow_execution' } @after_wake),
        'the body has not completed yet (parked on the re-armed condition)');

    my @after_advance = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 120 },
        jobs      => [
            { do_update => {
                id                   => 'u-advance',
                protocol_instance_id => 'pi-advance',
                name                 => 'advance',
                input                => [],
                run_validator        => 1,
            } },
        ],
    }));

    # The crux: the re-armed condition must still be pending so `advance` wakes
    # it. Under the drop bug there is no pending condition here -> no completion.
    my @complete = grep { $_->which_variant eq 'complete_workflow_execution' } @after_advance;
    T2->is(scalar @complete, 1,
        'advance wakes the re-armed condition and the body completes');
    T2->is(
        $PC->from_payload($complete[0]->complete_workflow_execution->result),
        'rearmed',
        'the resumed :Run ran past both wait_conditions');
});

T2->done_testing;
