# ABOUTME: Regression repro for finding R4b (spec R9): a whole-workflow cancel
# ABOUTME: while the body is parked on a plain untracked Future must produce a
# ABOUTME: CancelWorkflowExecution completion. Pre-fix, the fallback natively
# ABOUTME: cancelled the main run Future and _build_completion's ->result croaked
# ABOUTME: "was cancelled" — the activation died and NO completion was sent.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use WfDef::PlainFutureParker ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# ---------------------------------------------------------------------------
# The body awaits a Temporalio::Workflow::Future registered in NO pending map,
# so only the _apply_cancel_workflow fallback can reach it. The cancelled main
# run Future must map to the CancelWorkflowExecution outcome (no die, no
# missing completion).
# ---------------------------------------------------------------------------
T2->subtest('cancel while parked on a plain Future -> CancelWorkflowExecution (R9)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::PlainFutureParker',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'PlainFutureParker' } },
        ],
    }));
    T2->is(scalar @init, 0, 'init emits no commands (body parked untracked)');

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    T2->is($completion->which_status, 'successful',
        'the cancel activation produces a successful completion');
    my @commands = $harness->commands_of($completion);
    T2->is(scalar @commands, 1, 'exactly one command');
    T2->is($commands[0]->which_variant, 'cancel_workflow_execution',
        'the cancelled run maps to CancelWorkflowExecution (no croak)');
});

T2->done_testing;
