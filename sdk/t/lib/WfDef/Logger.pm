# ABOUTME: Fixture workflow that logs via Temporalio::Workflow::logger to drive
# ABOUTME: the replay-suppression test (T-wf-9) in determinism.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run emits one info-level log line carrying the message passed as its
# argument. The replay harness drives the same body once with is_replaying false
# (the line should reach the underlying logger) and once with is_replaying true
# (the line should be suppressed) — spec section 10.4 / T-wf-9.
class WfDef::Logger :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($message = 'hello from workflow') {
        my $log = Temporalio::Workflow::logger();
        $log->info($message);
        return 'logged';
    }
}

1;
