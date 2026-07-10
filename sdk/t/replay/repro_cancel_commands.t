# ABOUTME: Regression repro for B2 C-CANCEL-CMD bug #6: a try_cancel activity
# ABOUTME: under whole-workflow cancel must emit EXACTLY ONE CancelWorkflowExecution
# ABOUTME: and a single RequestCancelActivity across the run. The runner had no
# ABOUTME: "terminal command already emitted" guard, so the activity's post-cancel
# ABOUTME: ResolveActivity re-ran the outcome table and emitted a SECOND
# ABOUTME: CancelWorkflowExecution ([RequestCancelActivity, Cancel, Cancel]),
# ABOUTME: which core rejected and stalled the worker.
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
# #6: a try_cancel activity under whole-workflow cancel.
#
# The saga awaits a quick Reserve activity (seq 1, completes), then the long
# Process activity (seq 2, try_cancel) and parks. A CancelWorkflow cancels the
# pending Process Future (emitting a single RequestCancelActivity(2)) and
# raises Cancelled in the body; the body catches it, "runs cleanup", and
# re-raises, so the run ends CancelWorkflowExecution. Core THEN delivers the
# Process activity's cancelled ResolveActivity (seq 2).
#
# Under bug #6 that post-terminal activation re-ran the outcome table (the
# :Run Future was still ready+failed-Cancelled) and emitted a SECOND
# CancelWorkflowExecution, yielding [RequestCancelActivity, Cancel, Cancel]
# across the run, the invalid sequence core rejected. The fix is a run-scoped
# "terminal command already emitted" guard: at most one Cancel total.
# ---------------------------------------------------------------------------
T2->subtest('try_cancel activity under workflow cancel: one Cancel, one RequestCancelActivity (#6)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TryCancelSaga',
    );

    my @all;   # every command emitted across the whole run.

    my @a1 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'TryCancelSaga' } },
        ],
    }));
    push @all, @a1;
    T2->is($a1[0]->which_variant, 'schedule_activity',
        'init schedules the Reserve activity (seq 1)');

    # Reserve completes -> the body schedules the long Process activity (seq 2).
    my @a2 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [
            { resolve_activity => {
                seq    => 1,
                result => { completed => { result => payload('reserved') } },
            } },
        ],
    }));
    push @all, @a2;
    my ($sa) = grep { $_->which_variant eq 'schedule_activity' } @a2;
    T2->ok($sa, 'Reserve resolution schedules the Process activity');
    T2->is($sa->schedule_activity->cancellation_type, 0,
        'Process is try_cancel (cancellation_type 0), not abandon');

    # CancelWorkflow: cancels the pending Process Future (RequestCancelActivity)
    # and the re-raised Cancelled closes the run (CancelWorkflowExecution).
    my @a3 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    push @all, @a3;

    # Post-terminal activation: core delivers the cancelled Process activity's
    # ResolveActivity (seq 2). This is the activation that emitted the duplicate
    # CancelWorkflowExecution under the bug.
    my @a4 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 4 },
        jobs      => [
            { resolve_activity => {
                seq    => 2,
                result => { cancelled => { failure => { message => 'cancelled' } } },
            } },
        ],
    }));
    push @all, @a4;

    # The crux: across the WHOLE run, exactly one CancelWorkflowExecution and a
    # single RequestCancelActivity. Under bug #6 there were TWO Cancels.
    my @cancels = grep { $_->which_variant eq 'cancel_workflow_execution' } @all;
    my @reqcancels = grep { $_->which_variant eq 'request_cancel_activity' } @all;
    T2->is(scalar @cancels, 1,
        'exactly one CancelWorkflowExecution across the run (no duplicate, #6)');
    T2->is(scalar @reqcancels, 1,
        'exactly one RequestCancelActivity across the run');
    T2->is($reqcancels[0]->request_cancel_activity->seq, 2,
        'the RequestCancelActivity targets the Process activity seq (2)');

    # And no OTHER terminal command (Complete/Fail) sneaks in.
    my @other_terminal = grep {
        my $v = $_->which_variant;
        $v eq 'complete_workflow_execution' || $v eq 'fail_workflow_execution';
    } @all;
    T2->is(scalar @other_terminal, 0,
        'no Complete/Fail terminal command; the run ends purely Cancelled');
});

T2->done_testing;
