# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): memo and header
# ABOUTME: payloads are codec-encoded outbound / decoded inbound; SAs excluded.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surfaces: InitializeWorkflow.memo / .headers (inbound decode),
# ScheduleActivity.headers and StartChildWorkflowExecution.input/.memo/.headers
# (outbound encode). Search attributes are the pinned negative on BOTH
# directions: the boundary never offers SA payloads to the codec chain
# (sdk-python skip_search_attributes; step-45 Review Record sub-claim 1).

T2->subtest('inbound init memo and headers are codec-decoded; SAs are not' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::MemoEcho']);

    # SAs come off the server codec-FREE (they are never encoded); the typed
    # payload below is the exact server-side shape.
    my $sa_payload = {
        metadata => { encoding => 'json/plain', type => 'Keyword' },
        data     => '"sa-in"',
    };

    my $completion = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'MemoEcho',
            arguments     => [],
            memo    => { fields => { reason => $cb->marked_payload('memo-in') } },
            headers => { h_in => $cb->marked_payload('header-in') },
            search_attributes => {
                indexed_fields => { CustomKeywordField => $sa_payload },
            },
        } },
    ]);

    # The body read info->{memo}{reason}: only possible when the boundary
    # decoded the memo payload before the runner seeded the memo view.
    my $complete = $cb->command_of($completion, 'complete_workflow_execution');
    T2->ok($complete, 'the memo-echoing workflow completed');
    T2->is(CodecBoundary::marked_value(
            $complete->complete_workflow_execution->result),
        'memo-in', 'the body saw the DECODED memo value');

    T2->ok((grep { ($_->data // '') eq '"header-in"' }
            $cb->codec->decoded->@*),
        'the codec decoded the init header payload at the worker boundary');

    # SA negative: the boundary never handed the SA payload to the codec, and
    # the runner's SA view still carries the intact server value.
    T2->ok(!(grep { ($_->data // '') eq '"sa-in"' }
            $cb->codec->decode_seen->@*),
        'the inbound search-attribute payload was NOT offered to the codec');
    T2->is($cb->dispatcher->runner('r1')->info->{search_attributes}{CustomKeywordField},
        'sa-in', 'the start-time search attribute arrived intact');
});

T2->subtest('outbound activity headers are codec-encoded' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::HeaderActivityCaller']);

    my $completion = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'HeaderActivityCaller',
            arguments     => [ $cb->marked_payload('Bob') ],
        } },
    ]);

    my $cmd = $cb->command_of($completion, 'schedule_activity');
    T2->ok($cmd, 'ScheduleActivity emitted on init');
    my $header = $cmd->schedule_activity->headers->{_request_id};
    T2->ok(CodecBoundary::is_marked($header),
        'the activity header payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($header), 'rid-act',
        'the wrapped header payload carries the original value');
    T2->ok(CodecBoundary::is_marked($cmd->schedule_activity->arguments->[0]),
        'the activity arguments stay codec-encoded (v0.1 surface intact)');
});

T2->subtest('outbound child memo and headers are codec-encoded; SAs are not' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::MemoHeaderChildStarter']);

    my $completion = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'MemoHeaderChildStarter',
            arguments     => [],
        } },
    ]);

    my $cmd = $cb->command_of($completion, 'start_child_workflow_execution');
    T2->ok($cmd, 'StartChildWorkflowExecution emitted on init');
    my $start = $cmd->start_child_workflow_execution;

    T2->ok(CodecBoundary::is_marked($start->input->[0]),
        'the child input payload is codec-encoded outbound');
    my $memo = $start->memo->{note};
    T2->ok(CodecBoundary::is_marked($memo),
        'the child memo payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($memo), 'child-memo',
        'the wrapped memo payload carries the original value');
    my $header = $start->headers->{h_child};
    T2->ok(CodecBoundary::is_marked($header),
        'the child header payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($header), 'child-header',
        'the wrapped header payload carries the original value');

    # SA negative: the child-start search attribute keeps its typed payload,
    # unwrapped, so the server can index it.
    my $sa = $start->search_attributes->indexed_fields->{CustomKeywordField};
    T2->ok($sa, 'the child-start search attribute is present');
    T2->ok(!CodecBoundary::is_marked($sa),
        'the child-start search-attribute payload is NOT codec-wrapped');
    T2->is($sa->metadata->{type}, 'Keyword',
        'the SA payload keeps its typed metadata');
    T2->is(CodecBoundary::plain_value($sa), 'child-sa',
        'the SA payload stays directly readable (no unwrap needed)');
});

T2->done_testing;
