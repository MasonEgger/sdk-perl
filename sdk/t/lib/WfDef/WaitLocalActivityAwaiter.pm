# ABOUTME: Fixture workflow that parks on a wait_cancellation_completed local
# ABOUTME: activity — drives spec R52 (finding L8): eviction must cancel the LA
# ABOUTME: unconditionally (ignoring the wait type) so the parked frame unwinds
# ABOUTME: and the run releases, instead of parking forever.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Cancelled ();

# The :Run awaits a wait-type LA without ever cancelling it. The test evicts
# the run while the body is parked here; the eviction contract requires the
# await to raise Cancelled (the frame unwinds, recorded in $observed) rather
# than abandoning the parked frame. $observed is package-scoped so the test can
# assert the unwind happened from outside the workflow.
package WfDef::WaitLocalActivityAwaiter { our $observed; }

class WfDef::WaitLocalActivityAwaiter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $h = Temporalio::Workflow::start_local_activity(
            'SayHello',
            args                   => ['x'],
            start_to_close_timeout => 60,
            cancellation_type      => 'wait_cancellation_completed',
        );
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
            $WfDef::WaitLocalActivityAwaiter::observed = $outcome;
        };
        return $outcome;
    }
}

1;
