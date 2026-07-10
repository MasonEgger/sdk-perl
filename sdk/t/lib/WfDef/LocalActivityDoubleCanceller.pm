# ABOUTME: Fixture workflow that starts a wait_cancellation_completed local
# ABOUTME: activity then cancels its handle TWICE in the same activation —
# ABOUTME: drives spec R53 (finding L10): at most one RequestCancelLocalActivity
# ABOUTME: command per LA seq, no matter how many times the handle is cancelled.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Cancelled ();

# The :Run starts a wait-type LA, double-cancels the handle (the second cancel
# must be a command-level no-op), then awaits it and reports the outcome. The
# wait type parks the future, so the body resumes only when a later
# ResolveActivity job arrives.
class WfDef::LocalActivityDoubleCanceller :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h = Temporalio::Workflow::start_local_activity(
            'SayHello',
            args                   => ['x'],
            start_to_close_timeout => 60,
            cancellation_type      => 'wait_cancellation_completed',
        );
        $h->cancel;
        $h->cancel;   # double-cancel: must NOT emit a second cancel command.
        my $outcome;
        eval {
            my $v = await $h;
            $outcome = "completed: $v";
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
