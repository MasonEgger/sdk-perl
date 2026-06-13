# ABOUTME: Replay tests for the workflow determinism primitives (spec section
# ABOUTME: 10.4 / 10.3): UpdateRandomSeed re-seeding, the replay-suppressed
# ABOUTME: logger (T-wf-9), and NotifyHasPatch / patched() / SetPatchMarker.
use v5.38;
use warnings;
use utf8;

# Log::Any::Test installs a capturing adapter; load it before Log::Any so the
# workflow logger's get_logger picks up the test adapter.
use Log::Any::Test;
use Log::Any;

use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

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
# UpdateRandomSeed re-seeds the workflow's deterministic generator. The first
# activation draws two ints; the second carries FireTimer (to resume the body)
# plus an UpdateRandomSeed job that re-seeds; the post-fire draws reflect the
# NEW seed, and the whole thing is deterministic for a fixed seed pair.
# ---------------------------------------------------------------------------
T2->subtest('UpdateRandomSeed re-seeds the generator deterministically' => sub {
    my sub run_pair ($seed1, $seed2) {
        my $harness = Temporalio::Test::WorkflowReplay->new(
            workflow_class => 'WfDef::RandomReseeder',
        );
        $harness->push_activation(activation({
            run_id    => 'r1',
            timestamp => { seconds => 100 },
            jobs      => [
                { initialize_workflow => {
                    workflow_type   => 'RandomReseeder',
                    randomness_seed => $seed1,
                } },
            ],
        }));
        my @commands = $harness->push_activation(activation({
            run_id    => 'r1',
            timestamp => { seconds => 101 },
            jobs      => [
                { update_random_seed => { randomness_seed => $seed2 } },
                { fire_timer         => { seq => 1 } },
            ],
        }));
        my ($complete) = grep {
            $_->which_variant eq 'complete_workflow_execution'
        } @commands;
        return $PC->from_payload(
            $complete->complete_workflow_execution->result);
    }

    my $a = run_pair(42, 7);
    my $b = run_pair(42, 7);
    my $c = run_pair(42, 99);

    T2->is($a, $b, 'same seed pair -> identical before+after sequence');
    T2->is($a->{before}, $b->{before},
        'pre-reseed draws are seeded from the start job');
    T2->isnt($a->{after}, $c->{after},
        'a different UpdateRandomSeed value changes the post-reseed draws');
    T2->is($a->{before}, $c->{before},
        'the pre-reseed draws are unchanged by the later UpdateRandomSeed');
});

# ---------------------------------------------------------------------------
# T-wf-9: the workflow logger discards output while is_replaying is true, and
# emits it when is_replaying is false. The is_* level methods always return
# true so user code can build messages regardless of replay state.
# ---------------------------------------------------------------------------
T2->subtest('logger is suppressed during replay (T-wf-9)' => sub {
    my $log = Log::Any->get_logger(category => 'Temporalio::Workflow');

    # Not replaying: the line reaches the underlying logger.
    $log->clear;
    Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Logger',
    )->push_activation(activation({
        run_id    => 'live',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'Logger',
                arguments     => [ payload('live line') ],
            } },
        ],
    }));
    $log->contains_ok(qr/live line/,
        'a log line emitted while not replaying reaches the logger');

    # Replaying: the line is suppressed.
    $log->clear;
    Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Logger',
    )->push_activation(activation({
        run_id       => 'replay',
        timestamp    => { seconds => 100 },
        is_replaying => 1,
        jobs         => [
            { initialize_workflow => {
                workflow_type => 'Logger',
                arguments     => [ payload('replay line') ],
            } },
        ],
    }));
    T2->is(scalar(@{ $log->msgs }), 0,
        'a log line emitted while replaying is suppressed');
});

# ---------------------------------------------------------------------------
# patched(): on a fresh (non-replay) run, patched() returns true and emits a
# SetPatchMarker command exactly once (memoized across repeated calls in the
# same run).
# ---------------------------------------------------------------------------
T2->subtest('patched() emits SetPatchMarker once on a live run' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Patcher',
    );
    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'Patcher',
                arguments     => [ payload('my-change') ],
            } },
        ],
    }));

    my @markers = grep { $_->which_variant eq 'set_patch_marker' } @commands;
    T2->is(scalar @markers, 1,
        'exactly one SetPatchMarker even though patched() was called twice');
    T2->is($markers[0]->set_patch_marker->patch_id, 'my-change',
        'the marker carries the patch id');

    my ($complete) = grep {
        $_->which_variant eq 'complete_workflow_execution'
    } @commands;
    my $value = $PC->from_payload(
        $complete->complete_workflow_execution->result);
    T2->is($value->{first}, 1, 'patched() returns true on a fresh run');
    T2->is($value->{second}, 1, 'the memoized second call also returns true');
});

# ---------------------------------------------------------------------------
# patched() during replay: WITHOUT a NotifyHasPatch job the patch is treated as
# absent (returns false, no SetPatchMarker). WITH a NotifyHasPatch job for the
# id, patched() returns the deterministic true answer and emits the marker.
# ---------------------------------------------------------------------------
T2->subtest('patched() during replay honours NotifyHasPatch' => sub {
    # Replay, patch NOT notified -> absent.
    my @absent = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Patcher',
    )->push_activation(activation({
        run_id       => 'r1',
        timestamp    => { seconds => 100 },
        is_replaying => 1,
        jobs         => [
            { initialize_workflow => {
                workflow_type => 'Patcher',
                arguments     => [ payload('my-change') ],
            } },
        ],
    }));
    T2->is(scalar(grep { $_->which_variant eq 'set_patch_marker' } @absent), 0,
        'no marker when replaying and the patch was not notified');
    my ($abs_complete) = grep {
        $_->which_variant eq 'complete_workflow_execution'
    } @absent;
    T2->is(
        $PC->from_payload($abs_complete->complete_workflow_execution->result)
            ->{first},
        0, 'patched() returns false during replay without NotifyHasPatch');

    # Replay, patch notified -> present.
    my @present = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Patcher',
    )->push_activation(activation({
        run_id       => 'r1',
        timestamp    => { seconds => 100 },
        is_replaying => 1,
        jobs         => [
            { notify_has_patch    => { patch_id => 'my-change' } },
            { initialize_workflow => {
                workflow_type => 'Patcher',
                arguments     => [ payload('my-change') ],
            } },
        ],
    }));
    T2->is(scalar(grep { $_->which_variant eq 'set_patch_marker' } @present), 1,
        'a notified patch emits its marker even during replay');
    my ($pres_complete) = grep {
        $_->which_variant eq 'complete_workflow_execution'
    } @present;
    T2->is(
        $PC->from_payload($pres_complete->complete_workflow_execution->result)
            ->{first},
        1, 'patched() returns true during replay when NotifyHasPatch was sent');
});

# ---------------------------------------------------------------------------
# A NotifyHasPatch job records the patch id in the runner's workflow info so a
# later patched() and introspection both see it (spec section 10.3 "record in
# workflow info").
# ---------------------------------------------------------------------------
T2->subtest('NotifyHasPatch records the patch id in workflow info' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Patcher',
    );
    $harness->push_activation(activation({
        run_id       => 'r1',
        timestamp    => { seconds => 100 },
        is_replaying => 1,
        jobs         => [
            { notify_has_patch    => { patch_id => 'my-change' } },
            { initialize_workflow => {
                workflow_type => 'Patcher',
                arguments     => [ payload('my-change') ],
            } },
        ],
    }));

    my $info = $harness->runner->info;
    T2->ok((grep { $_ eq 'my-change' } @{ $info->{patches} // [] }),
        'the notified patch id is present in workflow info');
});

T2->done_testing;
