# ABOUTME: Coverage for finding T8 (spec R40), TIMER arm: a body parked on a
# ABOUTME: timer await when cancel_workflow arrives catches the Cancelled and
# ABOUTME: runs a NEW cleanup timer to completion, in catch-and-complete and
# ABOUTME: catch-and-propagate shapes. Behavior fixed by the R8-R10 cluster; this
# ABOUTME: file is the ledger entry for its arm.
#
# Post-cancel replay coverage ledger (finding T8), four arms x two shapes:
#   activity        -> t/replay/repro_post_cancel_cleanup.t (R8-R10 repro)
#   child workflow  -> t/replay/post_cancel_child_workflow.t
#   timer           -> t/replay/post_cancel_timer.t (THIS FILE)
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
use WfDef::PostCancelTimer ();

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) { return $PC->to_payload($value) }

# Drive the shared front half of both shapes: init parks the body on the Main
# timer (seq 1, 300s); cancel_workflow raises Cancelled there, the body catches
# it and starts + awaits the cleanup timer (seq 2, 60s). Returns the harness
# plus the cancel activation's commands.
sub drive_to_cleanup_park ($shape) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::PostCancelTimer',
    );

    my @init = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 1 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'PostCancelTimer',
                arguments     => [ payload($shape) ],
            } },
        ],
    }));
    T2->is(scalar @init, 1, "$shape: init emits one command");
    T2->is($init[0]->which_variant, 'start_timer',
        "$shape: init starts the Main timer");
    T2->is($init[0]->start_timer->seq, 1, "$shape: Main timer is seq 1");
    T2->is($init[0]->start_timer->start_to_fire_timeout->seconds, 300,
        "$shape: Main timer fires in 300s");

    my @cancel = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 2 },
        jobs      => [ { cancel_workflow => {} } ],
    }));
    return ($harness, @cancel);
}

# Assertions shared by both shapes on the cancel activation: the cancel chain
# emits CancelTimer for the Main timer, the caught body starts the cleanup
# timer, and NO terminal command is emitted yet: the run is still alive
# awaiting the cleanup timer.
sub assert_cleanup_started ($shape, @cancel) {
    my %variants = map { $_->which_variant => 1 } @cancel;
    T2->ok($variants{cancel_timer},
        "$shape: cancel chain emits CancelTimer for the Main timer");
    my ($tcancel) = grep { $_->which_variant eq 'cancel_timer' } @cancel;
    T2->is($tcancel->cancel_timer->seq, 1,
        "$shape: the CancelTimer targets seq 1");
    T2->ok($variants{start_timer},
        "$shape: the caught body starts the cleanup timer");
    my ($start) = grep { $_->which_variant eq 'start_timer' } @cancel;
    T2->is($start->start_timer->seq, 2, "$shape: cleanup timer is seq 2");
    T2->is($start->start_timer->start_to_fire_timeout->seconds, 60,
        "$shape: cleanup timer fires in 60s");
    T2->ok(!$variants{cancel_workflow_execution},
        "$shape: NO CancelWorkflowExecution while the body awaits cleanup");
    T2->ok(!$variants{complete_workflow_execution},
        "$shape: NO CompleteWorkflowExecution while the body awaits cleanup");
    return;
}

# ---------------------------------------------------------------------------
# Catch-and-complete shape: the body returns normally after the cleanup timer
# fires, so the FireTimer COMPLETES the workflow.
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup timer runs to completion (T8, catch-and-complete)' => sub {
    my ($harness, @cancel) = drive_to_cleanup_park('complete');
    assert_cleanup_started('complete', @cancel);

    my @fire = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [ { fire_timer => { seq => 2 } } ],
    }));
    T2->is(scalar @fire, 1, 'complete: the cleanup fire emits one command');
    T2->is($fire[0]->which_variant, 'complete_workflow_execution',
        'complete: the cleanup fire completes the workflow');
    T2->is(
        $PC->from_payload($fire[0]->complete_workflow_execution->result),
        'cleaned:timer',
        'complete: the result carries the post-cleanup return value');
});

# ---------------------------------------------------------------------------
# Catch-and-propagate shape: the body re-raises the caught Cancelled after the
# cleanup timer fires, so the outcome is CancelWorkflowExecution: emitted only
# NOW, on the FireTimer, never on the cancel activation.
# ---------------------------------------------------------------------------
T2->subtest('post-cancel cleanup timer then re-raise (T8, catch-and-propagate)' => sub {
    my ($harness, @cancel) = drive_to_cleanup_park('propagate');
    assert_cleanup_started('propagate', @cancel);

    my @fire = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 3 },
        jobs      => [ { fire_timer => { seq => 2 } } ],
    }));
    T2->is(scalar @fire, 1, 'propagate: the cleanup fire emits one command');
    T2->is($fire[0]->which_variant, 'cancel_workflow_execution',
        'propagate: the re-raised Cancelled maps to CancelWorkflowExecution');
});

T2->done_testing;
