# ABOUTME: Integration target workflow — waits to observe an external signal then
# ABOUTME: a cancellation. Driven by the external_workflow integration test (T-ext-10).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The external-handle target: it waits for a 'go' signal (sent by the driver
# through an ExternalWorkflowHandle), records it, then parks until cancelled.
# When the driver cancels it, the wait raises Cancelled and the :Run returns the
# cancellation outcome — so the run reaches a terminal CANCELED state observable
# by the test. A :Query exposes whether the signal was observed.
class WfDef::ExtTarget :isa(Temporalio::Workflow::Definition) {
    field $signalled = 0;

    async method run :Run () {
        # Wait for the external signal first.
        await Temporalio::Workflow::wait_condition(sub { $signalled });
        # Then park on a long timer; the driver's cancel makes the timer Future
        # raise Temporalio::Exception::Cancelled here (its on_cancel override
        # emits CancelTimer and fails the await), which propagates out of :Run as
        # a CancelWorkflowExecution outcome (a bare fresh Future would surface a
        # raw "was cancelled" string instead).
        await Temporalio::Workflow::sleep(3600);
        return 'unreachable';
    }

    method on_go :Signal('go') ($value = 'x') {
        $signalled = 1;
        return;
    }

    method was_signalled :Query('was_signalled') () {
        return $signalled ? 1 : 0;
    }
}

1;
