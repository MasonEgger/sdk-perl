# ABOUTME: Direct tests for Temporalio::Activity::ChildCancellation (spec R50,
# ABOUTME: finding T2): construction, cancellation observation, the live-cancel
# ABOUTME: poll hook, and the wait_any-loser race the class clones from
# ABOUTME: Temporalio::Cancellation (spec R23, finding R2).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Temporalio::Activity::ChildCancellation ();

# Spec section 9.4 / R50 (finding T2): the fork-safe token a sync activity
# sees inside a pool child had ZERO direct unit coverage; it was exercised
# only incidentally through pool tests. These are the direct tests, including
# the R23 wait_any race shape the class clones from Temporalio::Cancellation.

T2->subtest('construction: default token is not cancelled, future pending' => sub {
    my $token = Temporalio::Activity::ChildCancellation->new;

    T2->ok(!$token->is_cancelled, 'default token reports is_cancelled false');

    my $f = $token->cancelled;
    T2->isa_ok($f, 'Future');
    T2->ok(!$f->is_ready, 'cancelled Future is pending before cancel');
});

T2->subtest('construction: cancelled => 1 starts cancelled' => sub {
    my $token = Temporalio::Activity::ChildCancellation->new(cancelled => 1);

    T2->ok($token->is_cancelled, 'pre-cancelled token reports is_cancelled true');

    my $f = $token->cancelled;
    T2->ok($f->is_ready, 'cancelled Future is already resolved');
    T2->ok($f->is_done,  'cancelled Future resolved as a success');
});

T2->subtest('cancel: flag flips, held future resolves, idempotent' => sub {
    my $token = Temporalio::Activity::ChildCancellation->new;

    my $held = $token->cancelled;
    T2->ok(!$held->is_ready, 'Future fetched before cancel starts pending');

    $token->cancel;

    T2->ok($token->is_cancelled, 'is_cancelled true after cancel');
    T2->ok($held->is_ready,      'previously-pending Future is resolved');
    T2->ok($held->is_done,       'previously-pending Future resolved successfully');

    my $ok = eval { $token->cancel for 1 .. 3; 1 };
    T2->ok($ok, 'repeated cancel calls live') or T2->note($@);

    my $later = $token->cancelled;
    T2->ok($later->is_done, 'consumer attached after cancel sees resolution');
});

T2->subtest('poll hook: a live-channel cancel is observed (spec R19)' => sub {
    my $cancel_arrived = 0;
    my $token          = Temporalio::Activity::ChildCancellation->new(
        poll => sub { $cancel_arrived },
    );

    T2->ok(!$token->is_cancelled, 'no cancel while the poll reports false');

    my $held = $token->cancelled;
    T2->ok(!$held->is_ready, 'future pending while the poll reports false');

    $cancel_arrived = 1;

    T2->ok($token->is_cancelled, 'is_cancelled observes the polled cancel');
    T2->ok($held->is_done,       'held future resolves when the poll lands');

    # cancelled() itself must also give a live-channel cancel a chance to
    # land, without an intervening is_cancelled call.
    my $flag  = 0;
    my $fresh = Temporalio::Activity::ChildCancellation->new(poll => sub { $flag });
    $flag = 1;
    T2->ok($fresh->cancelled->is_done, 'cancelled() consults the poll directly');
});

# Spec R23 shape applied to this class (findings R2/T2; adapted from
# verify-45/cancel-core/probe_r2_wait_any.pl). ChildCancellation cloned the
# shared-single-future defect from Temporalio::Cancellation: a Future->wait_any
# loser sweep cancelled the one shared future, cancel()'s `!$future->is_ready`
# guard then skipped ->done (cancelled counts as ready), and cancellation was
# never observable again. cancelled() must return a per-call consumer view
# that a loser sweep cannot poison.
T2->subtest('wait_any loser sweep cannot poison cancelled() (R23/R50, findings R2/T2)' => sub {
    my $token = Temporalio::Activity::ChildCancellation->new;

    my $held = $token->cancelled;

    for my $round (1, 2) {
        my $winner = Future->new;
        my $race   = Future->wait_any($token->cancelled, $winner);
        $winner->done("round-$round");
        T2->ok($race->is_done, "round $round: winner settles the race");
    }

    $token->cancel;

    T2->ok($token->is_cancelled, 'token reports cancelled after the sweeps');

    my $fresh = $token->cancelled;
    T2->ok($fresh->is_ready, 'fresh consumer future is ready after cancel');
    T2->ok($fresh->is_done,
        'fresh consumer observes cancellation as done, not a poisoned husk');
    T2->ok(!$fresh->is_cancelled,
        'fresh consumer future did not inherit the loser-sweep cancel');

    T2->ok($held->is_done,
        'consumer held from before the races also observes the cancel');
});

T2->done_testing;
