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
# encode). The CAN proto also carries search_attributes, but the Perl CAN
# builder does not populate them yet, so the SA negative for the exclusion
# mechanism is pinned on the upsert and child-start surfaces instead.
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
});

T2->done_testing;
