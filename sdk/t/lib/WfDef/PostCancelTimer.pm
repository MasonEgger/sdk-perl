# ABOUTME: Fixture workflow for R40 (finding T8, timer arm): parks on a timer via
# ABOUTME: Temporalio::Workflow::sleep, catches the whole-workflow Cancelled, then
# ABOUTME: awaits a NEW cleanup timer. The shape arg picks what happens after the
# ABOUTME: cleanup timer fires: 'complete' returns normally
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

# The timer arm of the T8 post-cancel ledger: the _apply_cancel_workflow sweep
# cancels the pending timer Future (emitting CancelTimer and failing it with
# Cancelled), and a post-cancel cleanup timer the catch block starts into
# %pending_timers must run to completion (spec R8 / Python parity).
class WfDef::PostCancelTimer :isa(Temporalio::Workflow::Definition) {
    async method run :Run('PostCancelTimer') ( $shape = 'complete' ) {
        my $ok = eval {
            await Temporalio::Workflow::sleep(300);
            1;
        };
        return 'no-cancel' if $ok;

        my $err = $@;
        die $err    ## no critic (ErrorHandling::RequireCarping)
            unless Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Cancelled');

        # Post-cancel cleanup work: a NEW timer started and awaited from the
        # catch block fires normally before the workflow closes.
        await Temporalio::Workflow::sleep(60);

        die $err if $shape eq 'propagate';    ## no critic (ErrorHandling::RequireCarping)
        return 'cleaned:timer';
    }
}

1;
