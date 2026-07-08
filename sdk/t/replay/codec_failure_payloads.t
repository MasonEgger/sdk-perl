# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): failure payloads
# ABOUTME: (application-error details) pass through the codec in both directions.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surface: Failure.application_failure_info.details (a Payloads message) on
# FailWorkflowExecution (outbound encode) and on ResolveActivity{failed}
# (inbound decode). The failure MESSAGE is proto text, not a payload — it must
# stay readable; only the embedded detail payloads wear the codec wrapper
# (sdk-python _visitor Failure traversal). No search attributes on this
# surface, so no SA negative here.

T2->subtest('outbound failure details are codec-encoded' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::DetailedFailer']);

    my $completion = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'DetailedFailer',
            arguments     => [],
        } },
    ]);

    my $cmd = $cb->command_of($completion, 'fail_workflow_execution');
    T2->ok($cmd, 'FailWorkflowExecution emitted for the thrown Application error');
    my $failure = $cmd->fail_workflow_execution->failure;
    T2->is($failure->message, 'detailed boom',
        'the failure message stays plain proto text (not a payload)');

    my $details = $failure->application_failure_info->details;
    T2->ok($details, 'the application failure carries its details');
    my $payload = $details->payloads->[0];
    T2->ok(CodecBoundary::is_marked($payload),
        'the details payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($payload), 'secret-detail',
        'the wrapped details payload carries the original value');
});

T2->subtest('inbound failure details are codec-decoded' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::ActivityFailureCatcher']);

    $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'ActivityFailureCatcher',
            arguments     => [],
        } },
    ]);

    # The activity fails; its ApplicationFailureInfo details payload arrives
    # codec-wrapped. The boundary must decode it before the failure converter
    # from_payloads it for the catching body.
    my $done = $cb->dispatch('r1', [
        { resolve_activity => {
            seq    => 1,
            result => { failed => { failure => {
                message                  => 'activity boom',
                application_failure_info => {
                    type    => 'Boom',
                    details => {
                        payloads => [ $cb->marked_payload('secret-in') ],
                    },
                },
            } } },
        } },
    ], seconds => 101);

    my $complete = $cb->command_of($done, 'complete_workflow_execution');
    T2->ok($complete, 'the body caught the failure and completed');
    T2->is(CodecBoundary::marked_value(
            $complete->complete_workflow_execution->result),
        'secret-in',
        'the body read the DECODED details value off the caught exception');
    T2->ok((grep { ($_->data // '') eq '"secret-in"' }
            $cb->codec->decoded->@*),
        'the codec decoded the failure details payload at the worker boundary');
});

T2->done_testing;
