# ABOUTME: Fixture workflow for R8 (finding R4): parks on a long activity, catches
# ABOUTME: the whole-workflow Cancelled, then awaits a NEW cleanup activity. The
# ABOUTME: shape arg picks what happens after cleanup: 'complete' returns the
# ABOUTME: cleanup result (CompleteWorkflowExecution), 'propagate' re-raises the
# ABOUTME: caught Cancelled (CancelWorkflowExecution).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The R4 probe body (spec R8): the pre-fix runner's _apply_cancel_workflow
# fallback cancelled the main run Future while this body was parked on the
# post-cancel Cleanup activity, so the Cleanup ScheduleActivity and a
# CancelWorkflowExecution landed in ONE completion and the later
# ResolveActivity died "already failed and cannot be ->done".
class WfDef::PostCancelCleanup :isa(Temporalio::Workflow::Definition) {
    async method run :Run('PostCancelCleanup') ( $shape = 'complete' ) {
        my $ok = eval {
            await Temporalio::Workflow::start_activity(
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

        # Post-cancel cleanup work (Python parity: a body that catches the
        # cancellation may schedule and await new work, and that work completes
        # normally before the workflow closes).
        my $cleaned = await Temporalio::Workflow::start_activity(
            'Cleanup',
            args                   => [],
            start_to_close_timeout => 60,
        );

        die $err if $shape eq 'propagate';    ## no critic (ErrorHandling::RequireCarping)
        return "cleaned:$cleaned";
    }
}

1;
