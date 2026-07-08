# ABOUTME: Fixture workflow for R40 (finding T8, child-workflow arm): parks on a
# ABOUTME: child-workflow result await, catches the whole-workflow Cancelled, then
# ABOUTME: executes a NEW cleanup child workflow. The shape arg picks what happens
# ABOUTME: after cleanup: 'complete' returns the cleanup result
# ABOUTME: (CompleteWorkflowExecution), 'propagate' re-raises the caught Cancelled
# ABOUTME: (CancelWorkflowExecution).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The child-workflow arm of the T8 post-cancel ledger: the _apply_cancel_workflow
# sweep fails the pending child awaits with Cancelled (regardless of the child's
# cancellation_type), and post-cancel cleanup work the catch block schedules into
# %pending_child_workflows must run to completion (spec R8 / Python parity).
class WfDef::PostCancelChildWorkflow :isa(Temporalio::Workflow::Definition) {
    async method run :Run('PostCancelChildWorkflow') ( $shape = 'complete' ) {
        my $ok = eval {
            await Temporalio::Workflow::execute_child_workflow(
                'MainChild',
                id   => 'child-main',
                args => [],
            );
            1;
        };
        return 'no-cancel' if $ok;

        my $err = $@;
        die $err    ## no critic (ErrorHandling::RequireCarping)
            unless Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Cancelled');

        # Post-cancel cleanup work: a NEW child workflow scheduled and awaited
        # from the catch block completes normally before the workflow closes.
        my $cleaned = await Temporalio::Workflow::execute_child_workflow(
            'CleanupChild',
            id   => 'child-cleanup',
            args => [],
        );

        die $err if $shape eq 'propagate';    ## no critic (ErrorHandling::RequireCarping)
        return "cleaned:$cleaned";
    }
}

1;
