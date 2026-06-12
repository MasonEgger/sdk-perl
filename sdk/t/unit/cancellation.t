# ABOUTME: Tests Temporalio::Cancellation (spec section 4.4): fresh token is
# ABOUTME: pending (T-can-1), cancel resolves and flips the flag (T-can-2),
# ABOUTME: repeated cancel is idempotent (T-can-3).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Cancellation ();

# Spec section 4.4: Temporalio::Cancellation wraps a
# TemporalCoreCancellationToken for client-side cancellation of long-running
# RPCs and worker-side cancellation propagation. All operations after
# construction are infallible.

T2->subtest('new token: is_cancelled false, cancelled Future pending (T-can-1)' => sub {
    my $token = Temporalio::Cancellation->new;

    T2->ok(!$token->is_cancelled, 'fresh token reports is_cancelled false');

    my $f = $token->cancelled;
    T2->isa_ok($f, 'Future');
    T2->ok(!$f->is_ready, 'cancelled Future is pending before cancel');
});

T2->subtest('cancel: flag set, pending Future resolves, later already-resolved (T-can-2)' => sub {
    my $token = Temporalio::Cancellation->new;

    my $pending = $token->cancelled;
    T2->ok(!$pending->is_ready, 'Future fetched before cancel starts pending');

    $token->cancel;

    T2->ok($token->is_cancelled, 'is_cancelled true after cancel');
    T2->ok($pending->is_ready,   'previously-pending Future is resolved');
    T2->ok($pending->is_done,    'previously-pending Future resolved successfully');

    my $later = $token->cancelled;
    T2->ok($later->is_ready, 'cancelled after cancel returns already-resolved');
    T2->ok($later->is_done,  'already-resolved Future is a success, not a failure');
});

T2->subtest('repeated cancel calls are idempotent (T-can-3)' => sub {
    my $token = Temporalio::Cancellation->new;

    my $ok = eval { $token->cancel for 1 .. 3; 1 };
    T2->ok($ok, 'three cancel calls live') or T2->note($@);

    T2->ok($token->is_cancelled,       'token still cancelled');
    T2->ok($token->cancelled->is_done, 'cancelled Future still resolved');

    # cancel on a token that was cancelled before any cancelled() call must
    # also be safe (no Future exists yet to double-resolve).
    my $fresh = Temporalio::Cancellation->new;
    $ok = eval { $fresh->cancel; $fresh->cancel; 1 };
    T2->ok($ok, 'cancel twice with no Future observer lives') or T2->note($@);
    T2->ok($fresh->cancelled->is_done, 'observer attached after the fact sees resolution');
});

T2->done_testing;
