# ABOUTME: Regression repro for B3 bug #5 (spec R70 / finding T10 conversion of
# ABOUTME: t/integration/repro_cancel_live.t): a workflow parked on a NEVER-TRUE
# ABOUTME: wait_condition, when cancelled, must end via CancelWorkflowExecution
# ABOUTME: WITHOUT a durable-timer workaround. Pre-fix the parked condition future
# ABOUTME: native-cancelled ("was cancelled" string), failing the workflow task
# ABOUTME: forever instead of unwinding the body to CancelWorkflowExecution.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use WfDef::NeverCondition ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# ---------------------------------------------------------------------------
# #5 (B3): the :Run parks on wait_condition(sub { 0 }) — cancellation is the
# only way out. The CancelWorkflow job must raise a throwable
# Temporalio::Exception::Cancelled into the parked frame (the @conditions sweep
# in Runner::_apply_cancel_workflow), so the body unwinds and the runner emits
# CancelWorkflowExecution.
#
# Mutation-checked (plan R70 step 1): with the @conditions sweep entry in
# _apply_cancel_workflow disabled, the cancel activation emitted NO
# cancel_workflow_execution ("exactly one CancelWorkflowExecution" failed), so
# this test fails if the #5 fix reverts.
# ---------------------------------------------------------------------------
T2->subtest('cancel of a never-true wait_condition park -> CancelWorkflowExecution (#5)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::NeverCondition',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'NeverCondition' } },
        ],
    }));
    T2->is(scalar @init, 0,
        'init parks on the never-true wait_condition (no commands, no timer workaround)');

    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    T2->is($completion->which_status, 'successful',
        'the cancel activation produces a successful completion (no task failure)');

    my @commands = $harness->commands_of($completion);
    my @cancel = grep { $_->which_variant eq 'cancel_workflow_execution' } @commands;
    T2->is(scalar @cancel, 1, 'exactly one CancelWorkflowExecution');
    T2->is(scalar @commands, 1, 'and no other command rides along');
});

T2->done_testing;
