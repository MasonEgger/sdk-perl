# ABOUTME: Regression repro for finding R4 (spec R8): a body that catches the
# ABOUTME: whole-workflow Cancelled and awaits a NEW cleanup activity must have
# ABOUTME: that work run to completion. Pre-fix, _apply_cancel_workflow's fallback
# ABOUTME: cancelled the main run Future mid-await, putting ScheduleActivity and
# ABOUTME: CancelWorkflowExecution in ONE completion; the later cleanup
# ABOUTME: ResolveActivity then died "already failed and cannot be ->done".
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;
use WfDef::PostCancelCleanup ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# Drive the shared front half of both shapes: init parks the body on the Main
# activity (seq 1); cancel_workflow raises Cancelled there, the body catches it
# and schedules + awaits the Cleanup activity (seq 2). Returns the harness plus
# the cancel activation's commands.
sub drive_to_cleanup_park ($shape) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::PostCancelCleanup',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'PostCancelCleanup',
                arguments     => [ payload($shape) ],
            } },
        ],
    }));
    T2->is(scalar @init, 1, "$shape: init emits one command");
    T2->is($init[0]->which_variant, 'schedule_activity',
        "$shape: init schedules the Main activity");
    T2->is($init[0]->schedule_activity->seq, 1,
        "$shape: Main activity is seq 1");

    my @cancel = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    return ($harness, @cancel);
}

# Assertions shared by both shapes on the cancel activation: the cancel chain
# emits RequestCancelActivity for Main, the caught body schedules Cleanup, and
# NO terminal command is emitted yet — the run is still alive awaiting the
# cleanup activity. Pre-fix, cancel_workflow_execution rode along here (the R4
# "ScheduleActivity and CancelWorkflowExecution in one completion" corruption).
sub assert_cleanup_scheduled ($shape, @cancel) {
    my %variants = map { $_->which_variant => 1 } @cancel;
    T2->ok($variants{request_cancel_activity},
        "$shape: cancel chain emits RequestCancelActivity for Main");
    T2->ok($variants{schedule_activity},
        "$shape: the caught body schedules the Cleanup activity");
    my ($sched) = grep { $_->which_variant eq 'schedule_activity' } @cancel;
    T2->is($sched->schedule_activity->activity_type, 'Cleanup',
        "$shape: the post-cancel ScheduleActivity is the Cleanup activity");
    T2->is($sched->schedule_activity->seq, 2, "$shape: Cleanup is seq 2");
    T2->ok(!$variants{cancel_workflow_execution},
        "$shape: NO CancelWorkflowExecution while the body awaits cleanup");
    return;
}

# ---------------------------------------------------------------------------
# Catch-and-complete shape: the body returns the cleanup result after cleanup,
# so the cleanup resolution COMPLETES the workflow. Pre-fix, activation 3 died
# inside push_activation: "... is already failed and cannot be ->done" (the
# fallback had already failed the AWAIT_CLONEd main run Future).
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup runs to completion (R8, catch-and-complete)' => sub {
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
        'complete: the result carries the cleanup activity result');
});

# ---------------------------------------------------------------------------
# Catch-and-propagate shape: the body re-raises the caught Cancelled after the
# cleanup completes, so the outcome is CancelWorkflowExecution — emitted only
# NOW, on the cleanup resolution, never on the cancel activation.
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup then re-raise (R8, catch-and-propagate)' => sub {
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
