# ABOUTME: Regression repro for B4 bug #2 (spec R70 / finding T10 conversion of
# ABOUTME: t/integration/repro_external_signal.t): workflow A signals workflow B
# ABOUTME: TWICE through get_external_workflow_handle, awaiting each grant. The
# ABOUTME: guarded shape is the sequential hand-off: the SECOND signal command is
# ABOUTME: only emitted after the FIRST resolves, and the target's two signal jobs
# ABOUTME: both land. (Generic seq-space coverage lives in external_workflow.t;
# ABOUTME: this file keeps the exact #2 driver/target pair green.)
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;
use WfDef::TwiceSignaller ();
use WfDef::TwiceCounter ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# ---------------------------------------------------------------------------
# Driver side (#2): TwiceSignaller awaits each ->signal in turn, so the second
# SignalExternalWorkflowExecution must be emitted by the activation that
# resolves the first — the cross-workflow hand-off after the first grant that
# the B4 investigation guarded.
# ---------------------------------------------------------------------------
T2->subtest('second external signal is emitted after the first grant (#2 driver)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TwiceSignaller',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TwiceSignaller',
                arguments     => [ payload('target-1') ],
            } },
        ],
    }));
    T2->is(scalar @init, 1, 'init emits exactly the first signal command');
    T2->is($init[0]->which_variant, 'signal_external_workflow_execution',
        'the first command is SignalExternalWorkflowExecution');
    my $first = $init[0]->signal_external_workflow_execution;
    T2->is($first->seq, 1, 'first signal is seq 1');
    T2->is($first->signal_name, 'tick', 'first signal is tick');
    T2->is($first->workflow_execution->workflow_id, 'target-1',
        'first signal targets the handle id');

    # The first grant: exactly one MORE signal command must come out (the
    # pre-investigation worry was the hand-off stalling here).
    my @after_grant = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [ { resolve_signal_external_workflow => { seq => 1 } } ],
    }));
    T2->is(scalar @after_grant, 1, 'the first grant hands off to the second signal');
    T2->is($after_grant[0]->which_variant, 'signal_external_workflow_execution',
        'the follow-up command is the second SignalExternalWorkflowExecution');
    T2->is($after_grant[0]->signal_external_workflow_execution->seq, 2,
        'second signal is seq 2');

    # The second grant completes the driver with 'done'.
    my @after_second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [ { resolve_signal_external_workflow => { seq => 2 } } ],
    }));
    T2->is(scalar @after_second, 1, 'one command after the second grant');
    T2->is($after_second[0]->which_variant, 'complete_workflow_execution',
        'the driver completes');
    T2->is(
        $PC->from_payload($after_second[0]->complete_workflow_execution->result),
        'done', 'the driver returned done after both signals were granted');
});

# ---------------------------------------------------------------------------
# Target side (#2): TwiceCounter parks on wait_condition(count >= 2); each
# delivered tick bumps the count, and only the SECOND tick completes the run
# with the observed count.
# ---------------------------------------------------------------------------
T2->subtest('both delivered signals land on the target (#2 target)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TwiceCounter',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'TwiceCounter' } },
        ],
    }));
    T2->is(scalar @init, 0, 'init parks on the count >= 2 wait_condition');

    my @after_first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'tick',
                input       => [ payload(1) ],
            } },
        ],
    }));
    T2->is(scalar @after_first, 0, 'one tick is not enough (still parked)');

    my @after_second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [
            { signal_workflow => {
                signal_name => 'tick',
                input       => [ payload(2) ],
            } },
        ],
    }));
    T2->is(scalar @after_second, 1, 'the second tick completes the run');
    T2->is($after_second[0]->which_variant, 'complete_workflow_execution',
        'the target completes');
    T2->is(
        $PC->from_payload($after_second[0]->complete_workflow_execution->result),
        2, 'the target observed BOTH signals (count 2)');
});

T2->done_testing;
