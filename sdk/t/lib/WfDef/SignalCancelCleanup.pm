# ABOUTME: Fixture workflow for spec F2's cancel arm: a PostCancelTimer-style
# ABOUTME: :Run that parks on a timer, catches the whole-workflow Cancelled and
# ABOUTME: awaits a NEW cleanup timer, PLUS an async :Signal handler parked on a
# ABOUTME: timer of its own. The cancel sweep resumes both. Only the body may
# ABOUTME: own the run's single CancelWorkflowExecution; a handler that claimed
# ABOUTME: the one-shot terminal slot mid-sweep would get the body's cleanup
# ABOUTME: StartTimer dropped. Drives t/replay/signal_handler_classification.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The body half is WfDef::PostCancelTimer's catch-and-complete shape (spec R8 /
# finding T8): cancellation is delivered once at the awaited point, the catch
# block schedules post-cancel cleanup work, and that work runs to completion
# before the run closes. What this fixture adds is a parked :Signal handler in
# the same run, so _apply_cancel_workflow's timer sweep resumes the handler too.
# Both timers live in %pending_timers, so which frame resumes first follows hash
# order; the observable command set must not depend on it.
class WfDef::SignalCancelCleanup :isa(Temporalio::Workflow::Definition) {
    async method run :Run('SignalCancelCleanup') () {
        my $ok = eval {
            await Temporalio::Workflow::sleep(300);
            1;
        };
        return 'no-cancel' if $ok;

        my $err = $@;
        die $err    ## no critic (ErrorHandling::RequireCarping)
            unless Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Cancelled');

        # Post-cancel cleanup: a NEW timer started and awaited from the catch
        # block. The run stays alive until it fires, so NO terminal command may
        # be emitted on the cancel activation by anyone, body or handler.
        await Temporalio::Workflow::sleep(60);
        return 'cleaned:signal-cancel';
    }

    # Parked on its own timer when the cancel arrives. The sweep cancels that
    # timer, which fails it Temporalio::Exception::Cancelled; the Cancelled
    # propagates out of the await and fails this handler's return Future. The
    # settlement classifies it 'cancelled' and must DEFER: the body owns the
    # single CancelWorkflowExecution, and it is not due yet.
    async method park :Signal('park') () {
        await Temporalio::Workflow::sleep(1);
        return 'unreachable';
    }
}

1;
