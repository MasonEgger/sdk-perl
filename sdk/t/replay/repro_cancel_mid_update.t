# ABOUTME: Regression repro for B3 bug #8 (spec R70 / finding T10 conversion of
# ABOUTME: t/integration/repro_cancel_mid_update.t): a CancelWorkflow landing while
# ABOUTME: an :Update handler is mid-flight (parked on a never-true wait_condition)
# ABOUTME: must produce a clean CancelWorkflowExecution, not hang the workflow task
# ABOUTME: (~183s pre-fix: the parked handler's condition future native-cancelled
# ABOUTME: and the completion never carried a terminal command).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use WfDef::UpdateParker ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# ---------------------------------------------------------------------------
# #8 (B3): :Run parks on wait_condition(sub { $done }); the `park` :Update
# handler accepts, then parks on its OWN never-true wait_condition. The cancel
# must raise a throwable Cancelled into BOTH parked frames (the @conditions
# sweep in Runner::_apply_cancel_workflow covers handler conditions too): the
# body unwinds to CancelWorkflowExecution and the in-flight handler settles
# instead of leaking a raw cancelled Future that wedges the task.
# ---------------------------------------------------------------------------
T2->subtest('cancel mid-:Update -> clean CancelWorkflowExecution, no wedge (#8)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::UpdateParker',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'UpdateParker' } },
        ],
    }));
    T2->is(scalar @init, 0, 'init parks the :Run body (no commands)');

    # The DoUpdate accepts and the handler parks mid-flight: an accepted
    # UpdateResponse and nothing else (no completed — the handler is parked,
    # which is exactly the wait_for_stage => 'accepted' point the live repro
    # cancelled at).
    my @after_update = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [
            { do_update => {
                id                   => 'u-park',
                protocol_instance_id => 'pi-park',
                name                 => 'park',
                input                => [],
                run_validator        => 1,
            } },
        ],
    }));
    my @responses = grep { $_->which_variant eq 'update_response' } @after_update;
    T2->is(scalar @responses, 1, 'the update activation emits one UpdateResponse');
    T2->is($responses[0]->update_response->which_response, 'accepted',
        'the update is accepted; the handler is parked mid-flight');
    T2->is(scalar @after_update, 1, 'no other command (the handler has not completed)');

    # The cancel lands mid-update. Pre-fix this activation hung the workflow
    # task; post-fix it must be a successful completion carrying exactly one
    # CancelWorkflowExecution.
    my $completion = $harness->push_activation_completion(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    T2->is($completion->which_status, 'successful',
        'the mid-update cancel produces a successful completion (no task failure)');

    my @commands = $harness->commands_of($completion);
    my @cancel = grep { $_->which_variant eq 'cancel_workflow_execution' } @commands;
    T2->is(scalar @cancel, 1, 'exactly one CancelWorkflowExecution');
});

T2->done_testing;
