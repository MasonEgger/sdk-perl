# ABOUTME: Cancellation-type replay tests for the merged step R12+R52+R53:
# ABOUTME: R12 (finding R7) regular activities must honor
# ABOUTME: WAIT_CANCELLATION_COMPLETED (park until the delivered resolution)
# ABOUTME: while TRY_CANCEL stays immediate; R52 (finding L8) evict must cancel
# ABOUTME: a wait-type local activity unconditionally so the run releases; R53
# ABOUTME: (finding L10) a wait-type LA double-cancel emits exactly ONE
# ABOUTME: RequestCancelLocalActivity command.
#
# Python-parity note (verified against ../sdk-python/temporalio/worker/
# _workflow_instance.py, run_activity + _ActivityHandle): on cancel, Python
# emits the RequestCancel command and KEEPS awaiting the shielded result
# future; core, not lang, differentiates the types (TRY_CANCEL resolves
# cancelled immediately, WAIT_CANCELLATION_COMPLETED resolves only when the
# activity actually finishes, carrying the real outcome, which may be a
# successful completion). The Perl regular-activity arm must therefore park
# under the wait type and resolve from the delivered ResolveActivity, exactly
# as the local-activity arm already does (T-local-11).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Temporalio::Converter::Data ();
use Temporalio::Converter::Failure;
use Temporalio::Converter::Payload;
use Temporalio::Core::Proto;
use Temporalio::Exception::Cancelled ();
use Temporalio::Test::WorkflowReplay;
use Temporalio::Worker::WorkflowDispatcher ();
use Temporalio::Worker::WorkflowRegistry ();

no warnings 'experimental::class';

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) {
    return $PC->to_payload($value);
}

sub cancelled_failure () {
    my $fc = Temporalio::Converter::Failure->default;
    return $fc->to_failure(
        Temporalio::Exception::Cancelled->new(message => 'cancelled'), $PC);
}

# ---------------------------------------------------------------------------
# R12 (finding R7): cancel of a WAIT_CANCELLATION_COMPLETED regular activity
# emits RequestCancelActivity but the future stays PENDING; the later
# ResolveActivity delivers the real outcome. Pre-fix, the regular-activity
# cancel arm failed the future Cancelled immediately (TRY_CANCEL semantics for
# every type) and dropped the eventual core resolution as stale.
# ---------------------------------------------------------------------------
T2->subtest('R12: wait_cancellation_completed parks until the cancelled resolve' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCanceller',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'ActivityCanceller',
            arguments     => [ payload('wait_cancellation_completed') ] } } ],
    }));

    my %v1;
    $v1{ $_->which_variant }++ for @first;
    T2->is($v1{schedule_activity}, 1, 'scheduled the activity');
    T2->is($first[0]->schedule_activity->cancellation_type, 1,
        'cancellation_type marshals to WAIT_CANCELLATION_COMPLETED (1)');
    T2->is($v1{request_cancel_activity}, 1,
        'cancel command emitted immediately');
    T2->ok(!$v1{complete_workflow_execution} && !$v1{cancel_workflow_execution},
        'the future stays PENDING: no terminal command until the resolution job');

    # The cancelled resolution finally arrives -> Cancelled at the await ->
    # the body catches it and completes with 'cancelled'.
    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { resolve_activity => {
            seq    => 1,
            result => { cancelled => { failure => cancelled_failure() } } } } ],
    }));

    my %v2;
    $v2{ $_->which_variant }++ for @second;
    T2->is($v2{complete_workflow_execution}, 1,
        'the cancelled resolve resumes the parked body');
    T2->is($PC->from_payload(
            $second[-1]->complete_workflow_execution->result),
        'cancelled', 'the parked await finally raised Cancelled');
});

# ---------------------------------------------------------------------------
# R12: the delivered outcome is carried as-is. An activity that ignores the
# cancel and completes successfully resolves the parked future ->done with the
# result (Python parity: the shielded result future carries whatever core
# delivered, not a synthetic Cancelled).
# ---------------------------------------------------------------------------
T2->subtest('R12: wait type carries a successful delivered outcome' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCanceller',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'ActivityCanceller',
            arguments     => [ payload('wait_cancellation_completed') ] } } ],
    }));

    my %v1;
    $v1{ $_->which_variant }++ for @first;
    T2->ok(!$v1{complete_workflow_execution},
        'no terminal command while the cancel-requested activity runs on');

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { resolve_activity => {
            seq    => 1,
            result => { completed => { result => payload('Hello, x!') } } } } ],
    }));

    my %v2;
    $v2{ $_->which_variant }++ for @second;
    T2->is($v2{complete_workflow_execution}, 1,
        'the successful resolve resumes the parked body');
    T2->is($PC->from_payload(
            $second[-1]->complete_workflow_execution->result),
        'completed: Hello, x!',
        'the await resolved with the DELIVERED outcome, not a synthetic Cancelled');
});

# ---------------------------------------------------------------------------
# R12: TRY_CANCEL behavior is UNCHANGED — cancel resolves the future Cancelled
# in the same activation (core is asked to cancel best-effort; the later stale
# ResolveActivity is tolerated, per T-act-9).
# ---------------------------------------------------------------------------
T2->subtest('R12: try_cancel still resolves Cancelled immediately' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCanceller',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'ActivityCanceller',
            arguments     => [ payload('try_cancel') ] } } ],
    }));

    my %v;
    $v{ $_->which_variant }++ for @commands;
    T2->is($v{schedule_activity}, 1, 'scheduled the activity');
    T2->is($v{request_cancel_activity}, 1,
        'try_cancel emits RequestCancelActivity');
    T2->is($v{complete_workflow_execution}, 1,
        'try_cancel resolves Cancelled in the same activation (body resumes)');
    T2->is($PC->from_payload($commands[-1]->complete_workflow_execution->result),
        'cancelled', 'the await raised Temporalio::Exception::Cancelled');
});

# ---------------------------------------------------------------------------
# R53 (finding L10): a wait-type LA cancel is at-most-once. The handle is
# cancelled TWICE in the same activation; exactly ONE
# RequestCancelLocalActivity command may be emitted. Pre-fix, the wait branch
# of _on_local_activity_cancel had no sent-flag and pushed a duplicate.
# ---------------------------------------------------------------------------
T2->subtest('R53: double-cancel of a wait-type LA emits exactly one cancel command' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityDoubleCanceller',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LocalActivityDoubleCanceller' } } ],
    }));

    my %v1;
    $v1{ $_->which_variant }++ for @first;
    T2->is($v1{schedule_local_activity}, 1, 'scheduled the LA');
    T2->is($v1{request_cancel_local_activity} // 0, 1,
        'exactly ONE RequestCancelLocalActivity despite the double cancel');
    T2->ok(!$v1{complete_workflow_execution} && !$v1{cancel_workflow_execution},
        'the wait-type future stays parked (no terminal command)');

    # The cancelled resolve still lands normally after the double cancel.
    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { resolve_activity => {
            seq => 1, is_local => 1,
            result => { cancelled => { failure => cancelled_failure() } } } } ],
    }));

    my %v2;
    $v2{ $_->which_variant }++ for @second;
    T2->is($v2{complete_workflow_execution}, 1,
        'the cancelled resolve resumes the body');
    T2->is($PC->from_payload(
            $second[-1]->complete_workflow_execution->result),
        'cancelled', 'the parked await raised Cancelled exactly once');
});

# ---------------------------------------------------------------------------
# R52 (finding L8): evicting a run parked on a wait-type LA must cancel the LA
# UNCONDITIONALLY (ignore the cancellation type). Pre-fix, evict reused the
# caller-facing wait-honoring cancel: the cancel command was emitted, the
# future stayed pending, and the parked frame was abandoned without ever
# unwinding — the fixture's catch block never ran. The eviction contract:
# the await raises Cancelled (frame unwinds, $observed set), the eviction
# completion is sent, and the runner is dropped. Dispatcher-driven, mirroring
# evict-sibling-delete.t.
# ---------------------------------------------------------------------------
T2->subtest('R52: evict cancels a wait-type LA unconditionally' => sub {
    my $Activation = Temporalio::Core::Proto::resolve(
        'coresdk.workflow_activation.WorkflowActivation');
    my $Completion = Temporalio::Core::Proto::resolve(
        'coresdk.workflow_completion.WorkflowActivationCompletion');

    my $registry = Temporalio::Worker::WorkflowRegistry->new(
        workflows => ['WfDef::WaitLocalActivityAwaiter']);
    my $completions = [];
    my $dispatcher  = Temporalio::Worker::WorkflowDispatcher->new(
        registry       => $registry,
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
    );

    $WfDef::WaitLocalActivityAwaiter::observed = undef;

    # Init: the body parks on the wait-type LA.
    $dispatcher->dispatch_task($Activation->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'WaitLocalActivityAwaiter' } } ],
    })->encode)->get;

    my $c0 = $Completion->decode($completions->[0]);
    my %variants = map { $_->which_variant => 1 }
        ($c0->successful->commands // [])->@*;
    T2->ok($variants{schedule_local_activity},
        'init scheduled the wait-type LA (body parked)');

    # Evict. The wait type must NOT park the teardown.
    my $err = T2->dies(sub {
        $dispatcher->dispatch_task($Activation->new({
            run_id => 'r1',
            jobs   => [ { remove_from_cache => { message => 'cache full' } } ],
        })->encode)->get;
    });
    T2->is($err, undef, 'evict completes without croaking');

    T2->is($WfDef::WaitLocalActivityAwaiter::observed, 'cancelled',
        'the parked await raised Cancelled during evict (frame unwound, no '
        . 'parked-forever hang)');
    T2->ok(!$dispatcher->has_runner('r1'), 'runner dropped after eviction');
    T2->is(scalar(@$completions), 2, 'the eviction completion was sent');
    my $c1 = $Completion->decode($completions->[-1]);
    T2->ok(defined $c1->successful, 'eviction completion is the empty success');
    T2->is(scalar(($c1->successful->commands // [])->@*), 0,
        'eviction completion carries no commands');
});

T2->done_testing;
