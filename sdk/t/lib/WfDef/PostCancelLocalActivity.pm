# ABOUTME: Fixture workflow for R40 (finding T8, local-activity arm): parks on a
# ABOUTME: local activity, catches the whole-workflow Cancelled, then awaits a NEW
# ABOUTME: cleanup local activity. The shape arg picks what happens after cleanup:
# ABOUTME: 'complete' returns the cleanup result (CompleteWorkflowExecution),
# ABOUTME: 'propagate' re-raises the caught Cancelled (CancelWorkflowExecution).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The local-activity arm of the T8 post-cancel ledger: the _apply_cancel_workflow
# sweep force-cancels the pending LA future (emitting RequestCancelLocalActivity
# and failing it with Cancelled, ignoring wait_cancellation_completed), and a
# post-cancel cleanup LA the catch block schedules into %pending_activities must
# run to completion (spec R8 / Python parity).
class WfDef::PostCancelLocalActivity :isa(Temporalio::Workflow::Definition) {
    async method run :Run('PostCancelLocalActivity') ( $shape = 'complete' ) {
        my $ok = eval {
            await Temporalio::Workflow::execute_local_activity(
                'Main',
                args                   => [],
                start_to_close_timeout => 300,
            );
            1;
        };
        return 'no-cancel' if $ok;

        my $err = $@;
        die $err    ## no critic (ErrorHandling::RequireCarping)
            unless Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Cancelled');

        # Post-cancel cleanup work: a NEW local activity scheduled and awaited
        # from the catch block completes normally before the workflow closes.
        my $cleaned = await Temporalio::Workflow::execute_local_activity(
            'Cleanup',
            args                   => [],
            start_to_close_timeout => 60,
        );

        die $err if $shape eq 'propagate';    ## no critic (ErrorHandling::RequireCarping)
        return "cleaned:$cleaned";
    }
}

1;
