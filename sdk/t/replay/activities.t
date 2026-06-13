# ABOUTME: Replay tests for workflow-side activity scheduling (spec section 10.2
# ABOUTME: execute_activity/start_activity + 10.3 seq allocation): ScheduleActivity
# ABOUTME: emission (T-wf-1), ResolveActivity success (T-wf-2) and failure
# ABOUTME: (T-wf-7), and two-activity seq allocation with out-of-order resolution.
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

# Build a WorkflowActivation proto with the given fields. The job list is the
# oneof-tagged hashref form the generated classes accept.
sub activation ($args) {
    my $class = 'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $class->new($args);
}

# Convert a Perl value to a temporal.api.common.v1.Payload (hashref form the
# generated proto accepts under arguments/result).
my $PC = Temporalio::Converter::Payload->default;

sub payload ($value) {
    my $p = $PC->to_payload($value);
    # Hand it to the proto as a fully-built Payload message.
    return $p;
}

# ---------------------------------------------------------------------------
# T-wf-1: a workflow that calls execute_activity emits exactly one
# ScheduleActivity command on the first (InitializeWorkflow) activation, with
# the right type, arguments, task queue, start_to_close timeout, and seq=1.
# The workflow body parks on the activity Future, so NO completion command is
# emitted yet.
# ---------------------------------------------------------------------------
T2->subtest('execute_activity emits ScheduleActivity (T-wf-1)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller',
    );

    my @commands = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityCaller',
                arguments     => [ payload('Alice') ],
            } },
        ],
    }));

    T2->is(scalar @commands, 1, 'exactly one command emitted');
    my $cmd = $commands[0];
    T2->is($cmd->which_variant, 'schedule_activity',
        'the command is ScheduleActivity');

    my $sa = $cmd->schedule_activity;
    T2->is($sa->seq, 1, 'seq starts at 1');
    T2->is($sa->activity_id, '1', 'activity_id defaults to the seq string');
    T2->is($sa->activity_type, 'SayHello', 'activity_type is the named activity');
    T2->is(scalar $sa->arguments->@*, 1, 'one argument payload');
    T2->is($PC->from_payload($sa->arguments->[0]), 'Alice',
        'argument round-trips to the passed value');
    T2->is($sa->start_to_close_timeout->seconds, 60,
        'start_to_close_timeout is 60s');
    # cancellation_type defaults to try_cancel (proto enum 0).
    T2->is($sa->cancellation_type, 0, 'cancellation_type defaults to try_cancel');
});

# ---------------------------------------------------------------------------
# T-wf-2: a second activation carrying ResolveActivity{seq:1, completed} resumes
# the awaiting body; the workflow then completes with the activity's result.
# ---------------------------------------------------------------------------
T2->subtest('ResolveActivity success resumes the await (T-wf-2)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller',
    );

    # First activation: schedule the activity.
    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityCaller',
                arguments     => [ payload('Alice') ],
            } },
        ],
    }));
    T2->is($first[0]->which_variant, 'schedule_activity',
        'first activation schedules the activity');

    # Second activation: resolve seq 1 with a result payload.
    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_activity => {
                seq    => 1,
                result => { completed => { result => payload('Hello, Alice!') } },
            } },
        ],
    }));

    T2->is(scalar @second, 1, 'one command after resolution');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'workflow completes after the activity resolves');
    my $result = $second[0]->complete_workflow_execution->result;
    T2->is($PC->from_payload($result), 'got: Hello, Alice!',
        'completion carries the post-activity return value');
});

# ---------------------------------------------------------------------------
# T-wf-7: ResolveActivity{seq:1, failed} raises an exception at the await site.
# The activity failure (an ActivityFailure wrapping the cause) escapes :Run, so
# (until the P3.7 outcome table) the runner surfaces it — we assert the
# exception is a Temporalio::Exception::Activity with its cause type populated.
# ---------------------------------------------------------------------------
T2->subtest('ResolveActivity failure raises Exception::Activity (T-wf-7)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityCaller',
    );

    $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityCaller',
                arguments     => [ payload('Alice') ],
            } },
        ],
    }));

    # Build an activity failure: an ActivityFailure whose cause is an
    # Application error of type 'BadInput'. The failure converter renders this
    # to the Failure proto the ResolveActivity job carries.
    my $fc = Temporalio::Converter::Failure->default;
    my $cause = Temporalio::Exception::Application->new(
        message => 'no good',
        type    => 'BadInput',
    );
    require Temporalio::Exception::Activity;
    my $act_exc = Temporalio::Exception::Activity->new(
        message      => 'Activity task failed',
        activity_id  => '1',
        activity_type => 'SayHello',
        cause        => $cause,
    );
    my $failure_proto = $fc->to_failure($act_exc, $PC);

    my $err = T2->dies(sub {
        $harness->push_activation(activation({
            run_id    => 'r1',
            timestamp => { seconds => 101 },
            jobs      => [
                { resolve_activity => {
                    seq    => 1,
                    result => { failed => { failure => $failure_proto } },
                } },
            ],
        }));
    });

    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Activity'),
        'await site raises Temporalio::Exception::Activity',
    ) or T2->diag("got: $err");
    T2->ok(
        Scalar::Util::blessed($err) && $err->can('cause') && defined $err->cause,
        'the activity error has a cause',
    );
    T2->is($err->cause->type, 'BadInput',
        'cause->type is the underlying application error type');
});

# ---------------------------------------------------------------------------
# Two concurrent start_activity calls get seq 1 and seq 2. Out-of-order
# resolution (seq 2 first, then seq 1) lands each result on the correct handle.
# ---------------------------------------------------------------------------
T2->subtest('two activities get seq 1/2; out-of-order resolution' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TwoActivities',
    );

    my @first = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => { workflow_type => 'TwoActivities' } },
        ],
    }));

    T2->is(scalar @first, 2, 'two ScheduleActivity commands emitted');
    T2->is($first[0]->schedule_activity->seq, 1, 'first activity seq 1');
    T2->is($first[0]->schedule_activity->activity_type, 'First',
        'first activity type');
    T2->is($first[1]->schedule_activity->seq, 2, 'second activity seq 2');
    T2->is($first[1]->schedule_activity->activity_type, 'Second',
        'second activity type');

    # Resolve seq 2 first, then seq 1 — in the SAME activation, out of order.
    my @second = $harness->push_activation(activation({
        run_id    => 'r1',
        timestamp => { seconds => 101 },
        jobs      => [
            { resolve_activity => {
                seq    => 2,
                result => { completed => { result => payload('two') } },
            } },
            { resolve_activity => {
                seq    => 1,
                result => { completed => { result => payload('one') } },
            } },
        ],
    }));

    T2->is(scalar @second, 1, 'one completion command');
    T2->is($second[0]->which_variant, 'complete_workflow_execution',
        'workflow completes once both activities resolve');
    my $result = $PC->from_payload(
        $second[0]->complete_workflow_execution->result);
    T2->is($result, [ 'one', 'two' ],
        'each result lands on its own handle (matched by seq, not arrival order)');
});

T2->done_testing;
