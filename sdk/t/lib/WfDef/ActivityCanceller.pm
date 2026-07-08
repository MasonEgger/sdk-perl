# ABOUTME: Fixture workflow that starts a REGULAR activity then explicitly
# ABOUTME: cancels its handle — drives spec R12 (finding R7): the regular-arm
# ABOUTME: try_cancel / wait_cancellation_completed cancellation-type split,
# ABOUTME: mirroring WfDef::LocalActivityCanceller on the local-activity arm.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Cancelled ();

# The :Run starts a regular activity with the cancellation_type passed as the
# :Run argument, immediately cancels its handle, then awaits it and reports the
# outcome:
#   'cancelled' if a Temporalio::Exception::Cancelled was raised at the await,
#   'completed: <v>' if a resolution arrived first (wait_cancellation_completed
#   carries the DELIVERED outcome, which may be a successful completion when
#   the activity ignores the cancel).
# try_cancel resolves Cancelled in the same activation as the cancel;
# wait_cancellation_completed parks until core sends ResolveActivity.
class WfDef::ActivityCanceller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($cancellation_type = 'try_cancel') {
        my $h = Temporalio::Workflow::start_activity(
            'SayHello',
            args                   => ['x'],
            start_to_close_timeout => 60,
            cancellation_type      => $cancellation_type,
        );
        $h->cancel;
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
