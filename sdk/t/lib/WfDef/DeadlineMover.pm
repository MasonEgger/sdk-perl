# ABOUTME: Fixture for bug #4 (B10 C-COND-TIMEOUT): the updatable-timer pattern, a
# ABOUTME: :Run loop that parks on wait_condition(sub { $updated }, timeout => remaining)
# ABOUTME: where remaining is recomputed from a LIVE deadline each iteration. A `move`
# ABOUTME: :Update moves the deadline EARLIER and flips $updated, which must wake the parked
# ABOUTME: long timer, cancel it, and re-arm a SHORT timer against the moved deadline. Bug #4
# ABOUTME: is the distinct timeout-timer cancel/re-arm path (NOT B1's plain re-park).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Timeout ();

# Sleep until an absolute wake epoch that a `move` :Update can pull earlier. Each
# loop iteration recomputes the remaining sleep from the LIVE $deadline and parks on a
# durable-timer-backed wait_condition over the live $updated flag. Two exits from the park:
#   - a `move` update set $updated => the wait returns normally; the loop clears $updated and
#     re-arms a timer for the NEW (shorter) remaining, cancelling the stale long timer;
#   - the timer elapsed with no update => the wait raises Timeout (deadline reached) => the loop
#     re-checks should_wake and exits.
# This is the timeout-timer cancel/re-arm path #4: arm a long timer, an :Update moves the
# deadline, re-arm a short timer against the moved deadline. The stale long timer must be cleanly
# cancelled and its (cancelled) future must not leave the re-armed condition parked forever.
class WfDef::DeadlineMover :isa(Temporalio::Workflow::Definition) {
    field $deadline;          # absolute wake epoch (seconds); moved by the `move` update
    field $updated = 0;       # flipped true by `move` to wake the parked timer

    async method run :Run ($wake_epoch) {
        $deadline = $wake_epoch;

        while (1) {
            my $now = Temporalio::Workflow::now->epoch;
            last if $now >= $deadline;

            $updated = 0;
            my $ok = eval {
                await Temporalio::Workflow::wait_condition(
                    sub { $updated },
                    timeout => ($deadline - $now),
                );
                1;
            };
            if (!$ok) {
                my $err = $@;
                die $err                 ## no critic (ErrorHandling::RequireCarping)
                    unless Scalar::Util::blessed($err)
                    && $err->isa('Temporalio::Exception::Timeout');
            }
        }

        # The actual workflow-now epoch it woke at, so the caller can confirm it woke at the
        # (possibly moved-nearer) deadline rather than sleeping the full original timer.
        return Temporalio::Workflow::now->epoch;
    }

    # Move the deadline to a new absolute wake epoch and wake the parked timer so the loop
    # re-arms against the new (here earlier) deadline in this same activation.
    method move :Update('move') ($new_wake_epoch) {
        $deadline = $new_wake_epoch;
        $updated  = 1;
        return 'moved';
    }
}

1;
