# ABOUTME: Fixture workflow for the R18 live-heartbeat integration test: calls
# ABOUTME: one activity with a heartbeat_timeout SHORTER than the activity's
# ABOUTME: runtime and maximum_attempts 1, so the workflow only succeeds when
# ABOUTME: the activity's heartbeats actually reach the server while it runs.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Common::RetryPolicy;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The activity body runs ~5s while heartbeating every ~0.5s; the 2s
# heartbeat_timeout fires only if those heartbeats do NOT reach the server
# live (the pre-R18 pool relayed them after the body returned, finding L13).
# maximum_attempts 1 turns a heartbeat timeout into a workflow failure the
# test can assert on instead of an invisible retry.
class WfDef::HeartbeatTimeoutCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $out = await Temporalio::Workflow::execute_activity(
            'SlowButHeartbeating',
            args                   => [],
            start_to_close_timeout => 30,
            heartbeat_timeout      => 2,
            retry_policy           => Temporalio::Common::RetryPolicy->new(
                maximum_attempts => 1,
            ),
        );
        return "got: $out";
    }
}

1;
