# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): continue-as-new
# ABOUTME: arguments, memo, and headers are codec-encoded outbound.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surface: ContinueAsNewWorkflowExecution.arguments/.memo/.headers (outbound
# encode), plus the SA-not-wrapped negative: the CAN builder populates
# search_attributes since spec R25, and the codec walker must skip them
# (sdk-python skip_search_attributes parity).
T2->subtest('continue-as-new payloads are codec-encoded outbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::CanWithMemo']);

    my $completion = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'CanWithMemo',
            arguments     => [ $cb->marked_payload(3) ],
        } },
    ]);

    my $cmd = $cb->command_of($completion, 'continue_as_new_workflow_execution');
    T2->ok($cmd, 'ContinueAsNewWorkflowExecution emitted');
    my $can = $cmd->continue_as_new_workflow_execution;

    my $arg = $can->arguments->[0];
    T2->ok(CodecBoundary::is_marked($arg),
        'the continue-as-new argument payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($arg), 4,
        'the wrapped argument carries the incremented counter (decoded input)');

    my $memo = $can->memo->{note};
    T2->ok(CodecBoundary::is_marked($memo),
        'the continue-as-new memo payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($memo), 'can-memo',
        'the wrapped memo payload carries the original value');

    my $header = $can->headers->{h_can};
    T2->ok(CodecBoundary::is_marked($header),
        'the continue-as-new header payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($header), 'can-header',
        'the wrapped header payload carries the original value');

    # SA-not-wrapped negative (spec R7 exclusion, on the R25-populated CAN
    # surface): search-attribute payloads must reach the wire un-coded so the
    # server can index them.
    my $sa_field = $can->search_attributes->indexed_fields->{CustomKeywordField};
    T2->ok($sa_field, 'the CAN command carries the search attribute');
    T2->ok(!CodecBoundary::is_marked($sa_field),
        'the search-attribute payload is NOT codec-encoded (SA exclusion)');
    T2->is($sa_field->metadata->{type}, 'Keyword',
        'the SA payload keeps its typed metadata on the wire');
});

T2->done_testing;
