# ABOUTME: End-to-end fixture workflow (P3.9): calls an activity that throws an
# ABOUTME: Application failure and lets it bubble — exercises failure propagation
# ABOUTME: (WorkflowFailure -> Activity -> Application) against a real server.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Common::RetryPolicy ();

# Failer workflow: schedule the FailingActivity and await it. The activity raises
# a Temporalio::Exception::Application; the activity failure surfaces at the
# await site, escapes :Run, and fails the workflow execution. The server records
# a WorkflowExecutionFailed whose cause chain is Activity -> Application(type).
class WfDef::E2EFailer :isa(Temporalio::Workflow::Definition) {
    async method run :Run('E2EFailer') () {
        await Temporalio::Workflow::execute_activity(
            'FailingActivity',
            args                   => [],
            start_to_close_timeout => 30,
            # One attempt only — no retries — so the failure surfaces promptly.
            retry_policy           =>
                Temporalio::Common::RetryPolicy->new(maximum_attempts => 1),
        );
        return 'unreachable';
    }
}

1;
