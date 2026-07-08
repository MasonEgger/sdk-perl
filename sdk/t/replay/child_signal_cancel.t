# ABOUTME: Replay tests for cancelling a child-workflow signal (finding R10 /
# ABOUTME: step R39): cancelling a pending child signal emits CancelSignalWorkflow
# ABOUTME: (parity with the external-signal arm, T-ext-9), and a signal resolved
# ABOUTME: before the cancel emits no cancel command (no late/double emit).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;

# Build a WorkflowActivation proto from the oneof-tagged hashref job form.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

sub harness_for ($class) {
    return Temporalio::Test::WorkflowReplay->new(workflow_class => $class);
}

# ---------------------------------------------------------------------------
# R39 main: cancelling an in-flight child signal's Future emits
# CancelSignalWorkflow{seq} on the same seq as the signal command — parity with
# the external-signal arm (T-ext-9) — without pre-emptively settling the run;
# the eventual ResolveSignalExternalWorkflow is dropped cleanly.
# ---------------------------------------------------------------------------
T2->subtest('cancelling a pending child signal emits CancelSignalWorkflow (R39)' => sub {
    my $h = harness_for('WfDef::ChildSignalCanceller');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'ChildSignalCanceller' } },
        ],
    }));

    # Resolve the child start: the body then signals and immediately cancels
    # the signal Future, so both commands land in this activation.
    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_child_workflow_execution_start => {
                seq => 1, succeeded => { run_id => 'run-abc' },
            } },
        ],
    }));

    my ($sig) = grep {
        $_->which_variant eq 'signal_external_workflow_execution'
    } @cmds;
    my ($cancel_sig) = grep {
        $_->which_variant eq 'cancel_signal_workflow'
    } @cmds;

    T2->ok(defined $sig, 'the child signal command is emitted');
    T2->is($sig->signal_external_workflow_execution->which_target,
        'child_workflow_id',
        'the signal targets the child_workflow_id oneof arm');
    T2->ok(defined $cancel_sig,
        'a CancelSignalWorkflow command is emitted for the cancelled child signal');
    T2->is($cancel_sig->cancel_signal_workflow->seq,
        $sig->signal_external_workflow_execution->seq,
        'CancelSignalWorkflow targets the same seq as the child signal');

    # No fail/complete in this activation — cancelling the frame does not
    # pre-emptively settle the run.
    my @terminal = grep {
        $_->which_variant eq 'complete_workflow_execution'
            || $_->which_variant eq 'fail_workflow_execution'
            || $_->which_variant eq 'cancel_workflow_execution'
    } @cmds;
    T2->is(scalar @terminal, 0,
        'the in-flight cancel does not pre-emptively complete or fail the run');

    # A later resolve settles the underlying (already-cancelled) Future without
    # error: the is_ready guard drops it cleanly (spec section 20.2).
    my @second = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { resolve_signal_external_workflow => { seq => 1 } } ],
    }));
    my @late_cancels = grep {
        $_->which_variant eq 'cancel_signal_workflow'
    } @second;
    T2->is(scalar @late_cancels, 0,
        'the late resolve does not re-emit CancelSignalWorkflow');
    T2->is(scalar @second, 0,
        'resolving the cancelled child signal does not crash or complete the parked run');
});

# ---------------------------------------------------------------------------
# R39 edge: a child signal that resolves BEFORE the cancel emits no
# CancelSignalWorkflow — cancelling a ready Future is a no-op, so the hook must
# fire at most once and never after the resolve.
# ---------------------------------------------------------------------------
T2->subtest('a child signal resolved before cancel emits no cancel command (R39 edge)' => sub {
    my $h = harness_for('WfDef::ChildSignalResolvedCancel');
    $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ChildSignalResolvedCancel',
            } },
        ],
    }));

    # Resolve the child start: the body signals and parks awaiting the ack.
    my @cmds = $h->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_child_workflow_execution_start => {
                seq => 1, succeeded => { run_id => 'run-abc' },
            } },
        ],
    }));
    my ($sig) = grep {
        $_->which_variant eq 'signal_external_workflow_execution'
    } @cmds;
    T2->ok(defined $sig, 'the child signal command is emitted');
    T2->is(scalar(grep { $_->which_variant eq 'cancel_signal_workflow' } @cmds),
        0, 'no cancel command while the signal is merely pending');

    # Resolve the signal: the body resumes and cancels the now-ready Future.
    # A ready Future ignores ->cancel, so no CancelSignalWorkflow may appear.
    my @third = $h->push_activation(activation({
        run_id => 'r1', timestamp => { seconds => 102 },
        jobs   => [ { resolve_signal_external_workflow => { seq => 1 } } ],
    }));
    my @cancels = grep {
        $_->which_variant eq 'cancel_signal_workflow'
    } @third;
    T2->is(scalar @cancels, 0,
        'cancelling an already-resolved child signal emits no CancelSignalWorkflow');

    my @terminal = grep {
        $_->which_variant eq 'complete_workflow_execution'
            || $_->which_variant eq 'fail_workflow_execution'
            || $_->which_variant eq 'cancel_workflow_execution'
    } @third;
    T2->is(scalar @terminal, 0,
        'the post-resolve cancel does not complete or fail the parked run');
});

T2->done_testing;
