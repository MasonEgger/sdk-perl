# ABOUTME: Fixture workflow that starts a timer then cancels it — drives the
# ABOUTME: CancelTimer command + Cancelled-resolution path in timers.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Cancelled ();

# The :Run starts a timer, immediately cancels its Future (which must emit a
# CancelTimer command and resolve the Future as cancelled), awaits it, catches
# the Cancelled exception, and completes normally. This exercises the
# Workflow::Future on_cancel path: ->cancel fires the runner's hook that emits
# CancelTimer and fails the Future with Temporalio::Exception::Cancelled.
class WfDef::TimerCanceller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($seconds = 60) {
        my $timer = Temporalio::Workflow::start_timer($seconds);
        $timer->cancel;
        my $outcome = 'fired';
        eval {
            await $timer;
            1;
        } or do {
            my $err = $@;
            $outcome = (Scalar::Util::blessed($err)
                && $err->isa('Temporalio::Exception::Cancelled'))
                ? 'cancelled' : "other: $err";
        };
        return $outcome;
    }
}

1;
