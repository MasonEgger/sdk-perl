# ABOUTME: End-to-end fixture workflow (P3.9): sleeps on a workflow timer, then
# ABOUTME: returns — exercises the StartTimer -> FireTimer path against a real
# ABOUTME: server worker.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Sleeper workflow: park on a workflow timer for $seconds, then complete. The
# server schedules the timer and fires it; the worker's runner resumes the
# body and returns "awake".
class WfDef::E2ESleeper :isa(Temporalio::Workflow::Definition) {
    async method run :Run('E2ESleeper') ($seconds = 1) {
        await Temporalio::Workflow::sleep($seconds);
        return 'awake';
    }
}

1;
