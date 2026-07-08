# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): upsert-memo
# ABOUTME: payloads are codec-encoded; upsert search attributes are NOT.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surfaces: ModifyWorkflowProperties.upserted_memo.fields (outbound encode)
# and UpsertWorkflowSearchAttributes.search_attributes.indexed_fields (the
# pinned SA NEGATIVE: never codec-wrapped, or the server could not index
# them — sdk-python skip_search_attributes; Review Record sub-claim 1).

T2->subtest('upserted memo payloads are codec-encoded outbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::MemoUpserter']);

    $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'MemoUpserter',
            arguments     => [],
        } },
    ]);

    my $completion = $cb->dispatch('r1', [
        { signal_workflow => {
            signal_name => 'set',
            input       => [ $cb->marked_payload('x') ],
        } },
    ], seconds => 101);

    my $cmd = $cb->command_of($completion, 'modify_workflow_properties');
    T2->ok($cmd, 'ModifyWorkflowProperties emitted for the memo upsert');
    my $field = $cmd->modify_workflow_properties->upserted_memo->fields->{reason};
    T2->ok(CodecBoundary::is_marked($field),
        'the upserted memo payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($field), 'x',
        'the wrapped memo payload carries the original (decoded) signal value');
});

T2->subtest('upsert search-attribute payloads are NOT codec-wrapped' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::SearchAttributeUpserter']);

    my $completion = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'SearchAttributeUpserter',
            arguments     => [],
        } },
    ]);

    my $cmd = $cb->command_of($completion, 'upsert_workflow_search_attributes');
    T2->ok($cmd, 'UpsertWorkflowSearchAttributes emitted on init');
    my $sa = $cmd->upsert_workflow_search_attributes->search_attributes
        ->indexed_fields->{CustomKeywordField};
    T2->ok($sa, 'the upserted key is present in indexed_fields');
    T2->ok(!CodecBoundary::is_marked($sa),
        'the upsert SA payload is NOT codec-wrapped (marker absent)');
    T2->is($sa->metadata->{type}, 'Keyword',
        'the SA payload keeps its typed metadata');
    T2->is(CodecBoundary::plain_value($sa), 'first',
        'the SA payload stays directly readable (no unwrap needed)');

    # The boundary never even offered the SA payload to the codec chain.
    T2->ok(!(grep { ($_->data // '') eq '"first"' }
            $cb->codec->encode_seen->@*),
        'the SA payload was NOT handed to the codec on encode');
});

T2->done_testing;
