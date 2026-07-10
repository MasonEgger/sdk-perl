# ABOUTME: Fixture workflow that starts a local activity then explicitly cancels
# ABOUTME: its handle — drives T-local-10/11/12 (try_cancel / wait_completed /
# ABOUTME: abandon cancellation-type behaviours for local activities).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Cancelled ();

# The :Run starts an LA with the cancellation_type passed as the :Run argument,
# immediately cancels its handle, then awaits it and reports the outcome:
#   'cancelled' if a Temporalio::Exception::Cancelled was raised at the await,
#   'completed: <v>' if a resolution arrived first (wait_cancellation_completed).
# try_cancel/abandon resolve Cancelled in the same activation as the cancel;
# wait_cancellation_completed parks until the server sends ResolveActivity.
class WfDef::LocalActivityCanceller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($cancellation_type = 'try_cancel') {
        my $h = Temporalio::Workflow::start_local_activity(
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
