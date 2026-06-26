# ABOUTME: Replay fixture for B2 bug #6: a saga whose long second step uses a
# ABOUTME: try_cancel activity (NOT the abandon workaround). A whole-workflow
# ABOUTME: cancel cancels that pending activity (RequestCancelActivity), the body
# ABOUTME: catches the Cancelled, runs cleanup, and re-raises so the run ends
# ABOUTME: Cancelled. Core then delivers the activity's cancelled resolution.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Cancelled ();

# Mirrors the cancellation sample's saga (Cancellation::Workflow) but keeps the
# Process step on its NATURAL try_cancel cancellation type instead of the
# 'abandon' workaround the sample adopted for bug #6. A quick Reserve step
# completes, then the body awaits the long Process activity. A CancelWorkflow
# cancels the pending Process Future (emitting one RequestCancelActivity), the
# await raises Cancelled, the body catches it, "runs cleanup", and re-raises so
# the run ends CancelWorkflowExecution. The point of the repro: core afterwards
# delivers the cancelled activity's ResolveActivity, and the runner must NOT
# re-emit a second CancelWorkflowExecution on that post-terminal activation.
class WfDef::TryCancelSaga :isa(Temporalio::Workflow::Definition) {
    async method run :Run('TryCancelSaga') ( $work_seconds = 300 ) {
        await Temporalio::Workflow::start_activity(
            'Reserve',
            args                   => [],
            start_to_close_timeout => 60,
        );

        my $ok = eval {
            await Temporalio::Workflow::start_activity(
                'Process',
                args                   => [$work_seconds],
                start_to_close_timeout => $work_seconds + 60,
                cancellation_type      => 'try_cancel',
            );
            1;
        };
        if ( !$ok ) {
            my $err = $@;
            # Cleanup would run here in a real saga; re-raise so the run ends
            # Cancelled (the runner emits CancelWorkflowExecution).
            die $err;    ## no critic (ErrorHandling::RequireCarping)
        }

        return 'job completed';
    }
}

1;
