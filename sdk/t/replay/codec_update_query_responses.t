# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): update and query
# ABOUTME: response payloads are codec-encoded outbound.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surfaces: QueryResult.succeeded.response (RespondToQuery) and
# UpdateResponse.completed (outbound encode). Neither carries search
# attributes, so no SA negative here.

T2->subtest('query response is codec-encoded outbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::QueryGreeter']);

    $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'QueryGreeter',
            arguments     => [],
        } },
    ]);

    my $completion = $cb->dispatch('r1', [
        { query_workflow => {
            query_id   => 'q-1',
            query_type => 'greeting',
            arguments  => [],
        } },
    ], seconds => 105);

    my $cmd = $cb->command_of($completion, 'respond_to_query');
    T2->ok($cmd, 'RespondToQuery emitted for the query');
    T2->is($cmd->respond_to_query->query_id, 'q-1',
        'the response carries the query id');
    my $response = $cmd->respond_to_query->succeeded->response;
    T2->ok(CodecBoundary::is_marked($response),
        'the query response payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($response), 'initial',
        'the wrapped response payload carries the handler return value');
});

T2->subtest('update response is codec-encoded outbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::UpdateCounter']);

    $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'UpdateCounter',
            arguments     => [],
        } },
    ]);

    my $completion = $cb->dispatch('r1', [
        { do_update => {
            id                   => 'u-1',
            protocol_instance_id => 'pi-1',
            name                 => 'add',
            input                => [ $cb->marked_payload(7) ],
            run_validator        => 1,
        } },
    ], seconds => 101);

    my @ur = grep { ($_->which_variant // '') eq 'update_response' }
        $cb->commands_of($completion);
    T2->is(scalar @ur, 2, 'accepted + completed update responses emitted');
    my $result = $ur[1]->update_response->completed;
    T2->ok(CodecBoundary::is_marked($result),
        'the update completion payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($result), 7,
        'the wrapped update result carries the handler return value');
});

T2->done_testing;
