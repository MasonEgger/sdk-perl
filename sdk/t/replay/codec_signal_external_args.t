# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): signal-external-
# ABOUTME: workflow arguments are codec-encoded outbound.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surface: SignalExternalWorkflowExecution.args (outbound encode). The resolve
# acknowledgement carries no payloads. No search attributes on this surface,
# so no SA negative here.
T2->subtest('signal-external arguments are codec-encoded outbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::ExternalSignaller']);

    my $init = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'ExternalSignaller',
            arguments     => [],
        } },
    ]);

    my $cmd = $cb->command_of($init, 'signal_external_workflow_execution');
    T2->ok($cmd, 'SignalExternalWorkflowExecution emitted on init');
    my $arg = $cmd->signal_external_workflow_execution->args->[0];
    T2->ok(CodecBoundary::is_marked($arg),
        'the signal-external argument payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($arg), 'x',
        'the wrapped argument carries the original value');

    # The acknowledgement resolves the await and the body completes.
    my $done = $cb->dispatch('r1', [
        { resolve_signal_external_workflow => { seq => 1 } },
    ], seconds => 101);
    my $complete = $cb->command_of($done, 'complete_workflow_execution');
    T2->ok($complete, 'the workflow completed after the signal acknowledgement');
    T2->is(CodecBoundary::marked_value(
            $complete->complete_workflow_execution->result),
        'other-wf', 'the completion carries the handle workflow id');
});

T2->done_testing;
