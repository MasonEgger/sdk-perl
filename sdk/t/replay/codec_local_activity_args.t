# ABOUTME: R7 codec-boundary replay test (spec R7, finding R6): local-activity
# ABOUTME: input arguments are codec-encoded outbound.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use CodecBoundary ();

# Surface: ScheduleLocalActivity.arguments (outbound encode). The result
# round-trip (ResolveActivity{completed}, a v0.1-covered inbound surface) is
# exercised end-to-end as the closing sanity check. No search attributes on
# this surface, so no SA negative here.
T2->subtest('local-activity arguments are codec-encoded outbound' => sub {
    my $cb = CodecBoundary->new(workflows => ['WfDef::LocalActivityCaller']);

    my $init = $cb->dispatch('r1', [
        { initialize_workflow => {
            workflow_type => 'LocalActivityCaller',
            arguments     => [ $cb->marked_payload('Alice') ],
        } },
    ]);

    my $cmd = $cb->command_of($init, 'schedule_local_activity');
    T2->ok($cmd, 'ScheduleLocalActivity emitted on init');
    my $arg = $cmd->schedule_local_activity->arguments->[0];
    T2->ok(CodecBoundary::is_marked($arg),
        'the local-activity argument payload is codec-encoded outbound');
    T2->is(CodecBoundary::marked_value($arg), 'Alice',
        'the wrapped argument carries the original (decoded) value');

    # End-to-end sanity: the LA result decodes inbound and completes the body.
    my $done = $cb->dispatch('r1', [
        { resolve_activity => {
            seq    => 1,
            result => { completed =>
                { result => $cb->marked_payload('Hello, Alice!') } },
        } },
    ], seconds => 101);
    my $complete = $cb->command_of($done, 'complete_workflow_execution');
    T2->ok($complete, 'the workflow completed on the LA result');
    T2->is(CodecBoundary::marked_value(
            $complete->complete_workflow_execution->result),
        'got: Hello, Alice!', 'the body received the DECODED LA result');
});

T2->done_testing;
