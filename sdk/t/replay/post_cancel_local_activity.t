# ABOUTME: Coverage for finding T8 (spec R40), LOCAL-ACTIVITY arm: a body parked
# ABOUTME: on a local-activity await when cancel_workflow arrives catches the
# ABOUTME: Cancelled and runs a NEW cleanup local activity to completion, in
# ABOUTME: catch-and-complete and catch-and-propagate shapes. Behavior fixed by
# ABOUTME: the R8-R10 cluster; this file is the ledger entry for its arm.
#
# Post-cancel replay coverage ledger (finding T8), four arms x two shapes:
#   activity        -> t/replay/repro_post_cancel_cleanup.t (R8-R10 repro)
#   child workflow  -> t/replay/post_cancel_child_workflow.t
#   timer           -> t/replay/post_cancel_timer.t
#   local activity  -> t/replay/post_cancel_local_activity.t (THIS FILE)
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;
use WfDef::PostCancelLocalActivity ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# Drive the shared front half of both shapes: init parks the body on the Main
# local activity (seq 1); cancel_workflow raises Cancelled there (the whole-
# workflow cancel force-cancels the LA, ignoring wait_cancellation_completed),
# the body catches it and schedules + awaits the Cleanup LA (seq 2). Returns
# the harness plus the cancel activation's commands.
sub drive_to_cleanup_park ($shape) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::PostCancelLocalActivity',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'PostCancelLocalActivity',
                arguments     => [ payload($shape) ],
            } },
        ],
    }));
    T2->is(scalar @init, 1, "$shape: init emits one command");
    T2->is($init[0]->which_variant, 'schedule_local_activity',
        "$shape: init schedules the Main local activity");
    T2->is($init[0]->schedule_local_activity->seq, 1,
        "$shape: Main LA is seq 1");
    T2->is($init[0]->schedule_local_activity->activity_type, 'Main',
        "$shape: Main LA type is Main");

    my @cancel = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    return ($harness, @cancel);
}

# Assertions shared by both shapes on the cancel activation: the cancel chain
# emits RequestCancelLocalActivity for Main, the caught body schedules the
# Cleanup LA, and NO terminal command is emitted yet: the run is still alive
# awaiting the cleanup local activity.
sub assert_cleanup_scheduled ($shape, @cancel) {
    my %variants = map { $_->which_variant => 1 } @cancel;
    T2->ok($variants{request_cancel_local_activity},
        "$shape: cancel chain emits RequestCancelLocalActivity for Main");
    my ($lcancel) = grep {
        $_->which_variant eq 'request_cancel_local_activity'
    } @cancel;
    T2->is($lcancel->request_cancel_local_activity->seq, 1,
        "$shape: the cancel targets LA seq 1");
    T2->ok($variants{schedule_local_activity},
        "$shape: the caught body schedules the Cleanup local activity");
    my ($sched) = grep {
        $_->which_variant eq 'schedule_local_activity'
    } @cancel;
    T2->is($sched->schedule_local_activity->activity_type, 'Cleanup',
        "$shape: the post-cancel ScheduleLocalActivity is the Cleanup LA");
    T2->is($sched->schedule_local_activity->seq, 2,
        "$shape: Cleanup LA is seq 2");
    T2->ok(!$variants{cancel_workflow_execution},
        "$shape: NO CancelWorkflowExecution while the body awaits cleanup");
    T2->ok(!$variants{complete_workflow_execution},
        "$shape: NO CompleteWorkflowExecution while the body awaits cleanup");
    return;
}

# ---------------------------------------------------------------------------
# Catch-and-complete shape: the body returns the cleanup LA result, so the
# cleanup resolution COMPLETES the workflow.
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup LA runs to completion (T8, catch-and-complete)' => sub {
    my ($harness, @cancel) = drive_to_cleanup_park('complete');
    assert_cleanup_scheduled('complete', @cancel);

    my @resolve = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [
            { resolve_activity => {
                seq    => 2,
                result => { completed => { result => payload('swept') } },
            } },
        ],
    }));
    T2->is(scalar @resolve, 1, 'complete: cleanup resolution emits one command');
    T2->is($resolve[0]->which_variant, 'complete_workflow_execution',
        'complete: cleanup resolution completes the workflow');
    T2->is(
        $PC->from_payload($resolve[0]->complete_workflow_execution->result),
        'cleaned:swept',
        'complete: the result carries the cleanup LA result');
});

# ---------------------------------------------------------------------------
# Catch-and-propagate shape: the body re-raises the caught Cancelled after the
# cleanup LA completes, so the outcome is CancelWorkflowExecution: emitted
# only NOW, on the cleanup resolution, never on the cancel activation.
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup LA then re-raise (T8, catch-and-propagate)' => sub {
    my ($harness, @cancel) = drive_to_cleanup_park('propagate');
    assert_cleanup_scheduled('propagate', @cancel);

    my @resolve = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [
            { resolve_activity => {
                seq    => 2,
                result => { completed => { result => payload('swept') } },
            } },
        ],
    }));
    T2->is(scalar @resolve, 1, 'propagate: cleanup resolution emits one command');
    T2->is($resolve[0]->which_variant, 'cancel_workflow_execution',
        'propagate: the re-raised Cancelled maps to CancelWorkflowExecution');
});

T2->done_testing;
