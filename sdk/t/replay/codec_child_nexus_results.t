# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): child-workflow
# ABOUTME: and nexus operation results are codec-decoded inbound.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surface: ResolveChildWorkflowExecution.result.completed.result and
# ResolveNexusOperation.result.completed (inbound decode), plus the paired
# outbound child input / nexus input encode. Neither surface carries search
# attributes on the resolution path, so no SA negative here.

T2->subtest('child-workflow result is codec-decoded inbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::ChildCaller']);

    my $init = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'ChildCaller',
            arguments     => [ $cb->marked_payload('Alice') ],
        } },
    ]);

    # Outbound: the StartChildWorkflowExecution input is codec-encoded.
    my $start = $cb->command_of($init, 'start_child_workflow_execution');
    T2->ok($start, 'StartChildWorkflowExecution emitted on init');
    T2->ok(CodecBoundary::is_marked(
            $start->start_child_workflow_execution->input->[0]),
        'child-start input payload is codec-encoded outbound');

    $cb->dispatch('r1', [
        { resolve_child_workflow_execution_start => {
            seq => 1, succeeded => { run_id => 'run-abc' },
        } },
    ], seconds => 101);

    # The child result arrives codec-wrapped; the boundary must decode it
    # before the runner converts it for the awaiting body.
    my $done = $cb->dispatch('r1', [
        { resolve_child_workflow_execution => {
            seq    => 1,
            result => { completed =>
                { result => $cb->marked_payload('Hello, Alice!') } },
        } },
    ], seconds => 102);

    my $complete = $cb->command_of($done, 'complete_workflow_execution');
    T2->ok($complete, 'the workflow completed on the child result');
    T2->is(CodecBoundary::marked_value(
            $complete->complete_workflow_execution->result),
        'got: Hello, Alice!',
        'the body received the DECODED child result');
    T2->ok((grep { ($_->data // '') eq '"Hello, Alice!"' }
            $cb->codec->decoded->@*),
        'the codec decoded the child result payload at the worker boundary');
});

T2->subtest('nexus operation result is codec-decoded inbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::NexusCaller']);

    my $init = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'NexusCaller',
            arguments     => [ $cb->marked_payload('world') ],
        } },
    ]);

    # Outbound: the ScheduleNexusOperation single input is codec-encoded.
    my $sched = $cb->command_of($init, 'schedule_nexus_operation');
    T2->ok($sched, 'ScheduleNexusOperation emitted on init');
    T2->ok(CodecBoundary::is_marked($sched->schedule_nexus_operation->input),
        'nexus input payload is codec-encoded outbound');

    # started_sync + the completed result land in one activation (T-nexus-2
    # shape); the completed payload arrives codec-wrapped.
    my $done = $cb->dispatch('r1', [
        { resolve_nexus_operation_start => { seq => 1, started_sync => 1 } },
        { resolve_nexus_operation => {
            seq    => 1,
            result => { completed => $cb->marked_payload('Hello, world!') },
        } },
    ], seconds => 101);

    my $complete = $cb->command_of($done, 'complete_workflow_execution');
    T2->ok($complete, 'the workflow completed on the nexus result');
    T2->is(CodecBoundary::marked_value(
            $complete->complete_workflow_execution->result),
        'Hello, world!',
        'the body received the DECODED nexus result');
    T2->ok((grep { ($_->data // '') eq '"Hello, world!"' }
            $cb->codec->decoded->@*),
        'the codec decoded the nexus result payload at the worker boundary');
});

T2->done_testing;
