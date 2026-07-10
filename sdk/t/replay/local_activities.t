# ABOUTME: Replay tests for workflow-side LOCAL activity scheduling (spec
# ABOUTME: section 21): ScheduleLocalActivity emission + shared activity seq
# ABOUTME: space, terminal resolve (completed/failed/non-retryable), the
# ABOUTME: backoff->server-timer->re-schedule loop, the three cancellation
# ABOUTME: types, and late-resolve tolerance after shutdown (T-local-1..15).
use v5.38;
use warnings;
use utf8;
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
use Temporalio::Converter::Failure;
use Temporalio::Exception::Application;

no warnings 'experimental::class';

sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) {
    return $PC->to_payload($value);
}

# ---------------------------------------------------------------------------
# T-local-1: execute_local_activity emits exactly one ScheduleLocalActivity
# command on the first activation, seq 1, with the right type/args/timeout and
# default cancellation_type try_cancel. The body parks (no completion yet).
# ---------------------------------------------------------------------------
T2->subtest('execute_local_activity emits ScheduleLocalActivity (T-local-1)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCaller',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'LocalActivityCaller',
                arguments     => [ payload('Alice') ],
            } },
        ],
    }));

    T2->is(scalar @commands, 1, 'exactly one command emitted');
    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'schedule_local_activity',
        'the command is ScheduleLocalActivity');

    my $sla = $cmd->schedule_local_activity;
    T2->is($sla->seq, 1, 'seq starts at 1 (shared activity seq space)');
    T2->is($sla->activity_id, '1', 'activity_id defaults to the seq string');
    T2->is($sla->activity_type, 'SayHello', 'activity_type is the named activity');
    T2->is(scalar $sla->arguments->@*, 1, 'one argument payload');
    T2->is($PC->from_payload($sla->arguments->[0]), 'Alice',
        'argument round-trips to the passed value');
    T2->is($sla->start_to_close_timeout->seconds, 60,
        'start_to_close_timeout is 60s');
    T2->is($sla->cancellation_type, 0,
        'cancellation_type defaults to try_cancel');
    # local_retry_threshold defaults to 60s.
    T2->is($sla->local_retry_threshold->seconds, 60,
        'local_retry_threshold defaults to 60s');
    # Fresh schedule (not a backoff re-schedule): attempt unset (proto zero).
    T2->is($sla->attempt, 0, 'attempt is 0 on a fresh schedule');
});

# ---------------------------------------------------------------------------
# T-local-2: an LA that outlives a WFT — the body keeps draining; a later
# activation carrying ResolveActivity{seq:1, completed} resumes it and the
# workflow completes with the value.
# ---------------------------------------------------------------------------
T2->subtest('ResolveActivity success resumes the await (T-local-2)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCaller',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'LocalActivityCaller',
                arguments     => [ payload('Alice') ],
            } },
        ],
    }));

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_activity => {
                seq      => 1,
                is_local => 1,
                result   => { completed => { result => payload('Hello, Alice!') } },
            } },
        ],
    }));

    T2->is(scalar @second, 1, 'one command after resolution');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'workflow completes after the LA resolves');
    T2->is($PC->from_payload($second[0]->complete_workflow_execution->result),
        'got: Hello, Alice!', 'completion carries the post-LA return value');
});

# ---------------------------------------------------------------------------
# T-local-3: three serial LAs -> three ScheduleLocalActivity commands, one per
# activation, seq 1/2/3 (each from the shared activity seq space).
# ---------------------------------------------------------------------------
T2->subtest('serial LAs emit three commands, seq 1/2/3 (T-local-3)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ThreeLocalActivities',
    );

    my @a1 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'ThreeLocalActivities' } } ],
    }));
    T2->is(scalar @a1, 1, 'first activation: one command');
    T2->is($a1[0]->schedule_local_activity->seq, 1, 'first LA seq 1');
    T2->is($a1[0]->schedule_local_activity->activity_type, 'First',
        'first LA type');

    my @a2 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { resolve_activity => {
            seq => 1, is_local => 1,
            result => { completed => { result => payload('a') } } } } ],
    }));
    T2->is(scalar @a2, 1, 'second activation: one command');
    T2->is($a2[0]->schedule_local_activity->seq, 2, 'second LA seq 2');
    T2->is($a2[0]->schedule_local_activity->activity_type, 'Second',
        'second LA type');

    my @a3 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 102 },
        jobs      => [ { resolve_activity => {
            seq => 2, is_local => 1,
            result => { completed => { result => payload('b') } } } } ],
    }));
    T2->is($a3[0]->schedule_local_activity->seq, 3, 'third LA seq 3');
    T2->is($a3[0]->schedule_local_activity->activity_type, 'Third',
        'third LA type');
});

# ---------------------------------------------------------------------------
# T-local-4: two concurrent LAs share the activity seq space (seq 1/2), and
# out-of-order resolution lands each result on the correct handle.
# ---------------------------------------------------------------------------
T2->subtest('concurrent LAs share seq space; out-of-order resolve (T-local-4)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ConcurrentLocalActivities',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'ConcurrentLocalActivities' } } ],
    }));

    T2->is(scalar @first, 2, 'two ScheduleLocalActivity commands emitted');
    T2->is($first[0]->schedule_local_activity->seq, 1, 'first LA seq 1');
    T2->is($first[1]->schedule_local_activity->seq, 2, 'second LA seq 2');

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_activity => {
                seq => 2, is_local => 1,
                result => { completed => { result => payload('two') } } } },
            { resolve_activity => {
                seq => 1, is_local => 1,
                result => { completed => { result => payload('one') } } } },
        ],
    }));

    T2->is(scalar @second, 1, 'one completion command');
    T2->is($PC->from_payload($second[0]->complete_workflow_execution->result),
        [ 'one', 'two' ],
        'each result lands on its own handle (matched by seq)');
});

# ---------------------------------------------------------------------------
# T-local-5/6/7: only the terminal failure reaches lang. A failed resolution
# (whatever the retry mechanics — core only resolves terminally) raises at the
# await; an ApplicationFailure escapes :Run -> FailWorkflowExecution. This one
# proto path covers retry exhaustion (T-local-5), a non-retryable failure from
# the activity (T-local-6), and a non_retryable_error_types match (T-local-7) —
# all reach lang identically as a single failed ResolveActivity (no LA-specific
# branch; core owns the retry decision).
# ---------------------------------------------------------------------------
T2->subtest('terminal LA failure -> FailWorkflowExecution (T-local-5/6/7)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCaller',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LocalActivityCaller',
            arguments     => [ payload('Alice') ] } } ],
    }));

    my $fc    = Temporalio::Converter::Failure->default;
    my $cause = Temporalio::Exception::Application->new(
        message       => 'no good',
        type          => 'BadInput',
        non_retryable => 1,
    );
    require Temporalio::Exception::Activity;
    my $act_exc = Temporalio::Exception::Activity->new(
        message       => 'Activity task failed',
        activity_id   => '1',
        activity_type => 'SayHello',
        cause         => $cause,
    );
    my $failure_proto = $fc->to_failure($act_exc, $PC);

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_activity => {
                seq => 1, is_local => 1,
                result => { failed => { failure => $failure_proto } } } },
        ],
    }));

    T2->is(scalar @commands, 1, 'one command');
    T2->is($commands[0]->which_variant, 'fail_workflow_execution',
        'the escaped LA failure fails the workflow execution');
    T2->is($commands[0]->fail_workflow_execution->failure
            ->cause->application_failure_info->type, 'BadInput',
        'failure cause preserves the underlying application error type');
});

# ---------------------------------------------------------------------------
# T-local-9: backoff_with_persistent_timer. A ResolveActivity{seq:1, backoff}
# does NOT resolve the outer future. The runner instead starts a real StartTimer
# for backoff_duration; when the timer fires, the runner re-emits
# ScheduleLocalActivity for the same type/args with a NEW seq, attempt from
# DoBackoff, and the preserved original_schedule_time. The body's single outer
# await is unaffected until a terminal resolution arrives on the new seq.
# ---------------------------------------------------------------------------
T2->subtest('backoff -> StartTimer -> re-schedule new seq (T-local-9)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCaller',
    );

    my @a1 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LocalActivityCaller',
            arguments     => [ payload('Alice') ] } } ],
    }));
    T2->is($a1[0]->schedule_local_activity->seq, 1, 'initial LA seq 1');

    # Build a DoBackoff resolution: attempt 5, backoff 7s, original schedule at
    # epoch 50.
    my @a2 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_activity => {
                seq => 1, is_local => 1,
                result => { backoff => {
                    attempt                => 5,
                    backoff_duration       => { seconds => 7 },
                    original_schedule_time => { seconds => 50 },
                } } } },
        ],
    }));

    # The backoff must NOT complete the workflow; it must emit a StartTimer for
    # the backoff duration.
    T2->is(scalar @a2, 1, 'backoff emits exactly one command');
    T2->is($a2[0]->which_variant, 'start_timer',
        'backoff starts a real server timer');
    T2->is($a2[0]->start_timer->start_to_fire_timeout->seconds, 7,
        'timer fires after backoff_duration');
    my $timer_seq = $a2[0]->start_timer->seq;

    # Fire the backoff timer: the runner re-emits ScheduleLocalActivity with a
    # NEW seq, the DoBackoff attempt, and the preserved original_schedule_time.
    my @a3 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 108 },
        jobs      => [ { fire_timer => { seq => $timer_seq } } ],
    }));

    T2->is(scalar @a3, 1, 'timer fire re-schedules the LA');
    T2->is($a3[0]->which_variant, 'schedule_local_activity',
        'the re-schedule is a ScheduleLocalActivity');
    my $resched = $a3[0]->schedule_local_activity;
    T2->isnt($resched->seq, 1, 'the re-schedule uses a NEW seq (not 1)');
    T2->is($resched->attempt, 5, 'attempt carried from DoBackoff');
    T2->is($resched->original_schedule_time->seconds, 50,
        'original_schedule_time preserved from DoBackoff');
    T2->is($resched->activity_type, 'SayHello',
        'same activity type re-scheduled');

    # A terminal completed on the NEW seq resolves the (single) outer future.
    my @a4 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 109 },
        jobs      => [ { resolve_activity => {
            seq => $resched->seq, is_local => 1,
            result => { completed => { result => payload('done') } } } } ],
    }));
    T2->is($a4[0]->which_variant, 'complete_workflow_execution',
        'terminal resolve on the new seq completes the workflow');
    T2->is($PC->from_payload($a4[0]->complete_workflow_execution->result),
        'got: done', 'the body saw exactly one result (backoff was invisible)');
});

# ---------------------------------------------------------------------------
# T-local-10: cancel_try_cancel. $handle->cancel emits RequestCancelLocalActivity
# and resolves the outer future Cancelled in the same activation. The Cancelled
# escapes :Run -> CancelWorkflowExecution.
# ---------------------------------------------------------------------------
T2->subtest('try_cancel emits RequestCancelLocalActivity + Cancelled (T-local-10)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCanceller',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LocalActivityCanceller',
            arguments     => [ payload('try_cancel') ] } } ],
    }));

    # One ScheduleLocalActivity, one RequestCancelLocalActivity; the body catches
    # the Cancelled raised at the await (in the same activation) and completes
    # normally with the 'cancelled' outcome string.
    my %by_variant;
    $by_variant{ $_->which_variant }++ for @commands;
    T2->is($by_variant{schedule_local_activity}, 1,
        'scheduled the LA');
    T2->is($by_variant{request_cancel_local_activity}, 1,
        'try_cancel emits RequestCancelLocalActivity');
    my ($cancel) = grep {
        $_->which_variant eq 'request_cancel_local_activity' } @commands;
    T2->is($cancel->request_cancel_local_activity->seq, 1,
        'cancel targets the LA seq');
    T2->is($by_variant{complete_workflow_execution}, 1,
        'try_cancel resolves Cancelled in the same activation (body resumes)');
    T2->is($PC->from_payload($commands[-1]->complete_workflow_execution->result),
        'cancelled', 'the await raised Temporalio::Exception::Cancelled');
});

# ---------------------------------------------------------------------------
# T-local-11: cancel_wait_completed. $handle->cancel emits
# RequestCancelLocalActivity but the outer future stays parked until a
# ResolveActivity{cancelled} job arrives.
# ---------------------------------------------------------------------------
T2->subtest('wait_cancellation_completed waits for the cancelled resolve (T-local-11)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCanceller',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LocalActivityCanceller',
            arguments     => [ payload('wait_cancellation_completed') ] } } ],
    }));

    my %v1;
    $v1{ $_->which_variant }++ for @first;
    T2->is($v1{schedule_local_activity}, 1, 'scheduled the LA');
    T2->is($v1{request_cancel_local_activity}, 1,
        'cancel command emitted immediately');
    T2->ok(!$v1{cancel_workflow_execution},
        'the workflow does NOT complete yet (waits for the cancelled resolve)');
    T2->is($first[0]->schedule_local_activity->cancellation_type, 1,
        'cancellation_type marshals to WAIT_CANCELLATION_COMPLETED (1)');

    # The cancelled resolution finally arrives -> Cancelled at the await ->
    # CancelWorkflowExecution.
    my $fc = Temporalio::Converter::Failure->default;
    require Temporalio::Exception::Cancelled;
    my $cancelled_failure = $fc->to_failure(
        Temporalio::Exception::Cancelled->new(message => 'cancelled'), $PC);

    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { resolve_activity => {
            seq => 1, is_local => 1,
            result => { cancelled => { failure => $cancelled_failure } } } } ],
    }));

    my %v2;
    $v2{ $_->which_variant }++ for @second;
    T2->is($v2{complete_workflow_execution}, 1,
        'the cancelled resolve resumes the body (which caught Cancelled)');
    T2->is($PC->from_payload(
            $second[-1]->complete_workflow_execution->result),
        'cancelled', 'the parked await finally raised Cancelled');
});

# ---------------------------------------------------------------------------
# T-local-12: cancel_abandon. $handle->cancel emits NO command and resolves the
# outer future Cancelled immediately.
# ---------------------------------------------------------------------------
T2->subtest('abandon emits no cancel command, resolves Cancelled now (T-local-12)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCanceller',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LocalActivityCanceller',
            arguments     => [ payload('abandon') ] } } ],
    }));

    my %v;
    $v{ $_->which_variant }++ for @commands;
    T2->is($v{schedule_local_activity}, 1, 'scheduled the LA');
    T2->ok(!$v{request_cancel_local_activity},
        'abandon emits NO RequestCancelLocalActivity');
    T2->is($v{complete_workflow_execution}, 1,
        'abandon resolves Cancelled immediately (body resumes same activation)');
    T2->is($PC->from_payload($commands[-1]->complete_workflow_execution->result),
        'cancelled', 'the await raised Cancelled with no cancel command sent');
    T2->is($commands[0]->schedule_local_activity->cancellation_type, 2,
        'cancellation_type marshals to ABANDON (2)');
});

# ---------------------------------------------------------------------------
# T-local-13: cancel_failing. A backing-off LA (parked on its server timer)
# cancelled by a whole-workflow CancelWorkflow job -> the pending backoff timer
# is cancelled (CancelTimer) and the outer future resolves Cancelled.
# ---------------------------------------------------------------------------
T2->subtest('cancel of a backing-off LA emits CancelTimer + Cancelled (T-local-13)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::LocalActivityCaller',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'LocalActivityCaller',
            arguments     => [ payload('Alice') ] } } ],
    }));

    # Drive the LA into a backoff: it now holds a pending server timer.
    my @a2 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { resolve_activity => {
            seq => 1, is_local => 1,
            result => { backoff => {
                attempt                => 2,
                backoff_duration       => { seconds => 30 },
                original_schedule_time => { seconds => 50 },
            } } } } ],
    }));
    T2->is($a2[0]->which_variant, 'start_timer',
        'backoff parked on a server timer');

    # A whole-workflow CancelWorkflow: the backing-off LA must cancel its pending
    # timer (CancelTimer) and resolve the outer future Cancelled.
    my @a3 = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 102 },
        jobs      => [ { cancel_workflow => {} } ],
    }));

    my %v;
    $v{ $_->which_variant }++ for @a3;
    T2->is($v{cancel_timer}, 1,
        'the pending backoff timer is cancelled (CancelTimer)');
    T2->is($v{cancel_workflow_execution}, 1,
        'the outer future resolves Cancelled -> CancelWorkflowExecution');
});

# ---------------------------------------------------------------------------
# T-local-14/15: late-resolve tolerance. After the body has finished (the
# workflow completed), a late ResolveActivity for an LA seq that already
# resolved is tolerated as stale — NOT flagged as non-determinism, no stuck
# workflow. We drive a completed workflow then feed a duplicate/late resolve and
# assert it produces no FailWorkflowExecution (the outcome table does not fail
# on a tolerated stale resolve).
# ---------------------------------------------------------------------------
T2->subtest('late LA resolve after completion is tolerated (T-local-14/15)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ConcurrentLocalActivities',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [ { initialize_workflow => {
            workflow_type => 'ConcurrentLocalActivities' } } ],
    }));

    # Cancel one LA via the handle path is not used here; instead resolve seq 1,
    # leaving seq 2 pending, then feed a STALE resolve for an unknown-but-
    # previously-cancelled seq to confirm tolerance. First resolve seq 1.
    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [ { resolve_activity => {
            seq => 1, is_local => 1,
            result => { completed => { result => payload('one') } } } } ],
    }));

    # Complete by resolving seq 2.
    my @done = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 102 },
        jobs      => [ { resolve_activity => {
            seq => 2, is_local => 1,
            result => { completed => { result => payload('two') } } } } ],
    }));
    T2->is($done[0]->which_variant, 'complete_workflow_execution',
        'workflow completed once both LAs resolved');

    # A late duplicate resolve for seq 2 (already resolved/removed) must be
    # tolerated: no command, definitely no FailWorkflowExecution.
    my @late = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 103 },
        jobs      => [ { resolve_activity => {
            seq => 2, is_local => 1,
            result => { completed => { result => payload('two-again') } } } } ],
    }));
    my $failed = grep { $_->which_variant eq 'fail_workflow_execution' } @late;
    T2->ok(!$failed, 'a late duplicate LA resolve does not fail the workflow');
});

T2->done_testing;
