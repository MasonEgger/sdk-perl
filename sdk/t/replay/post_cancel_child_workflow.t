# ABOUTME: Coverage for finding T8 (spec R40), CHILD-WORKFLOW arm: a body parked
# ABOUTME: on a child-workflow result await when cancel_workflow arrives catches
# ABOUTME: the Cancelled and runs NEW cleanup child-workflow work to completion,
# ABOUTME: in catch-and-complete and catch-and-propagate shapes. Behavior fixed by
# ABOUTME: the R8-R10 cluster; this file is the ledger entry for its arm.
#
# Post-cancel replay coverage ledger (finding T8), four arms x two shapes:
#   activity        -> t/replay/repro_post_cancel_cleanup.t (R8-R10 repro)
#   child workflow  -> t/replay/post_cancel_child_workflow.t (THIS FILE)
#   timer           -> t/replay/post_cancel_timer.t
#   local activity  -> t/replay/post_cancel_local_activity.t
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;
use WfDef::PostCancelChildWorkflow ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# Drive the shared front half of both shapes: init parks the body on the Main
# child's start await (seq 1); the start resolution moves it to the result
# await; cancel_workflow raises Cancelled there, the body catches it and starts
# + awaits the CleanupChild (seq 2). Returns the harness plus the cancel
# activation's commands.
sub drive_to_cleanup_park ($shape) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::PostCancelChildWorkflow',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'PostCancelChildWorkflow',
                arguments     => [ payload($shape) ],
            } },
        ],
    }));
    T2->is(scalar @init, 1, "$shape: init emits one command");
    T2->is($init[0]->which_variant, 'start_child_workflow_execution',
        "$shape: init starts the Main child workflow");
    T2->is($init[0]->start_child_workflow_execution->seq, 1,
        "$shape: Main child is seq 1");
    T2->is($init[0]->start_child_workflow_execution->workflow_type,
        'MainChild', "$shape: Main child type is MainChild");

    my @started = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [
            { resolve_child_workflow_execution_start => {
                seq => 1, succeeded => { run_id => 'run-main' },
            } },
        ],
    }));
    T2->is(scalar @started, 0,
        "$shape: start resolution parks the body on the result await");

    my @cancel = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    return ($harness, @cancel);
}

# Assertions shared by both shapes on the cancel activation: the cancel chain
# emits CancelChildWorkflowExecution for the Main child, the caught body starts
# the CleanupChild, and NO terminal command is emitted yet: the run is still
# alive awaiting the cleanup child's start.
sub assert_cleanup_started ($shape, @cancel) {
    my %variants = map { $_->which_variant => 1 } @cancel;
    T2->ok($variants{cancel_child_workflow_execution},
        "$shape: cancel chain emits CancelChildWorkflowExecution for Main");
    my ($ccancel) = grep {
        $_->which_variant eq 'cancel_child_workflow_execution'
    } @cancel;
    T2->is($ccancel->cancel_child_workflow_execution->child_workflow_seq, 1,
        "$shape: the cancel targets child_workflow_seq 1");
    T2->ok($variants{start_child_workflow_execution},
        "$shape: the caught body starts the CleanupChild workflow");
    my ($start) = grep {
        $_->which_variant eq 'start_child_workflow_execution'
    } @cancel;
    T2->is($start->start_child_workflow_execution->workflow_type,
        'CleanupChild', "$shape: the post-cancel start is the CleanupChild");
    T2->is($start->start_child_workflow_execution->seq, 2,
        "$shape: CleanupChild is seq 2");
    T2->ok(!$variants{cancel_workflow_execution},
        "$shape: NO CancelWorkflowExecution while the body awaits cleanup");
    T2->ok(!$variants{complete_workflow_execution},
        "$shape: NO CompleteWorkflowExecution while the body awaits cleanup");
    return;
}

# Resolve the CleanupChild's start then its result; return the commands from
# the result activation (the terminal one for both shapes).
sub resolve_cleanup ($harness, $shape) {
    my @started = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 4 },
        jobs      => [
            { resolve_child_workflow_execution_start => {
                seq => 2, succeeded => { run_id => 'run-cleanup' },
            } },
        ],
    }));
    T2->is(scalar @started, 0,
        "$shape: cleanup start resolution parks on the cleanup result await");

    return $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 5 },
        jobs      => [
            { resolve_child_workflow_execution => {
                seq    => 2,
                result => { completed => { result => payload('swept') } },
            } },
        ],
    }));
}

# ---------------------------------------------------------------------------
# Catch-and-complete shape: the body returns the cleanup child's result, so
# the cleanup resolution COMPLETES the workflow.
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup child runs to completion (T8, catch-and-complete)' => sub {
    my ($harness, @cancel) = drive_to_cleanup_park('complete');
    assert_cleanup_started('complete', @cancel);

    my @resolve = resolve_cleanup($harness, 'complete');
    T2->is(scalar @resolve, 1, 'complete: cleanup resolution emits one command');
    T2->is($resolve[0]->which_variant, 'complete_workflow_execution',
        'complete: cleanup resolution completes the workflow');
    T2->is(
        $PC->from_payload($resolve[0]->complete_workflow_execution->result),
        'cleaned:swept',
        'complete: the result carries the cleanup child result');
});

# ---------------------------------------------------------------------------
# Catch-and-propagate shape: the body re-raises the caught Cancelled after the
# cleanup child completes, so the outcome is CancelWorkflowExecution: emitted
# only NOW, on the cleanup resolution, never on the cancel activation.
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup child then re-raise (T8, catch-and-propagate)' => sub {
    my ($harness, @cancel) = drive_to_cleanup_park('propagate');
    assert_cleanup_started('propagate', @cancel);

    my @resolve = resolve_cleanup($harness, 'propagate');
    T2->is(scalar @resolve, 1, 'propagate: cleanup resolution emits one command');
    T2->is($resolve[0]->which_variant, 'cancel_workflow_execution',
        'propagate: the re-raised Cancelled maps to CancelWorkflowExecution');
});

T2->done_testing;
