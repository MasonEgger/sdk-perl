# ABOUTME: Regression repro for finding R4c (spec R10): a whole-workflow cancel
# ABOUTME: must sweep %pending_external_signals and %pending_external_cancels so a
# ABOUTME: body parked on an external-signal or external-cancel Future observes
# ABOUTME: Cancelled. Pre-fix, neither map was swept and push_activation died in
# ABOUTME: the main-run-future fallback ("was cancelled", no completion).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;
use WfDef::ExtSignalWait ();
use WfDef::ExtCancelWait ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

# Shared driver: init parks the body on the external-map Future (emitting the
# named command), then cancel_workflow must wake it with Cancelled; the body
# returns the 'observed-cancelled' marker, so the completion is a
# CompleteWorkflowExecution carrying that marker.
sub assert_cancel_wakes_parked_body ($label, $workflow_class, $workflow_type, $init_variant) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => $workflow_class,
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => { workflow_type => $workflow_type } },
        ],
    }));
    T2->is(scalar @init, 1, "$label: init emits one command");
    T2->is($init[0]->which_variant, $init_variant,
        "$label: init emits $init_variant and parks");

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    T2->is($completion->which_status, 'successful',
        "$label: the cancel activation produces a completion");
    my @commands = $harness->commands_of($completion);
    my ($complete) =
        grep { $_->which_variant eq 'complete_workflow_execution' } @commands;
    T2->ok(defined $complete,
        "$label: the parked body returned -> CompleteWorkflowExecution");
    T2->is(
        $PC->from_payload($complete->complete_workflow_execution->result),
        'observed-cancelled',
        "$label: the body observed Cancelled at the parked await");
    return;
}

# ---------------------------------------------------------------------------
# R10, external-signal map: body parked on signal_external_workflow_execution.
# ---------------------------------------------------------------------------
T2->subtest('cancel sweeps pending external signals (R10)' => sub {
    assert_cancel_wakes_parked_body(
        'ext-signal', 'WfDef::ExtSignalWait', 'ExtSignalWait',
        'signal_external_workflow_execution');
});

# ---------------------------------------------------------------------------
# R10, external-cancel map: body parked on the acknowledgement of a
# request_cancel_external_workflow_execution.
# ---------------------------------------------------------------------------
T2->subtest('cancel sweeps pending external cancels (R10)' => sub {
    assert_cancel_wakes_parked_body(
        'ext-cancel', 'WfDef::ExtCancelWait', 'ExtCancelWait',
        'request_cancel_external_workflow_execution');
});

T2->done_testing;
