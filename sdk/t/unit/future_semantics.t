# ABOUTME: Adapted step-45 probe (verify-45/memsafe-infra/future_semantics.pl):
# ABOUTME: pins the Future 0.52 wait_any loser states behind findings L26/T5/T6.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();

# The Test-helper await pattern is `$loop->await(Future->wait_any($future,
# $loop->timeout_future(after => $timeout)))` followed by branches on
# $future's state. IO::Async::Loop->timeout_future FAILS with "Timeout"
# after the delay, so on the timeout arm wait_any settles from a FAILED
# component; a plain `Future->fail("Timeout\n")` component reproduces the
# same transition synchronously and is what these pins use.
#
# The Future 0.52 loser states this file pins are the shared root cause of
# findings L26 (spec R33), T5 (spec R47), and T6 (spec R48):
#
#   1. wait_any CANCELS its losing components when the race settles.
#   2. A cancelled future is READY (is_ready true) but neither done nor
#      failed — so a diagnostic branch keyed on `!is_ready` is dead code
#      (T5/R47), and a success branch keyed on `is_ready && !is_failed`
#      matches a CANCELLED loser (T6/R48).
#   3. ->get on a cancelled future croaks the raw "was cancelled" message —
#      what callers actually saw instead of the intended diagnostics.
#   4. A late ->done on a cancelled future is silently DISCARDED, so a
#      late bridge completion (a dev-server CLI that started after the
#      timeout, a connection established after the timeout) can never be
#      observed, let alone reaped — the L26/R33 leak mechanism.
#   5. ->without_cancel shields the underlying future: wait_any cancels
#      the shield, the underlying stays PENDING, and a late completion is
#      still observable through a settle continuation — the hook the R3
#      deferred free and the R33 reapers hang off.
#
# If a Future upgrade changes any of these, the await helpers in
# Test/DevServer.pm, Test/Client.pm, and Test/Worker.pm need re-auditing;
# this file failing is the early warning.

T2->subtest('wait_any cancels its losing components' => sub {
    my $loser = Future->new;
    my $wait  = Future->wait_any($loser, Future->fail("Timeout\n"));
    T2->ok($wait->is_ready, 'wait_any settles from the failed (timeout) component');
    T2->ok($loser->is_cancelled, 'the pending loser is CANCELLED, not left pending');
    T2->ok($loser->is_ready,  'a cancelled future IS ready (is_ready keys on any settle)');
    T2->ok(!$loser->is_failed, 'a cancelled future is NOT failed');
    T2->ok(!$loser->is_done,   'a cancelled future is NOT done');
    my @reported = $wait->failure;    # retrieve so the failure is reported
});

T2->subtest('->get on a cancelled loser croaks the raw cancel message' => sub {
    my $loser = Future->new;
    my $wait  = Future->wait_any($loser, Future->fail("Timeout\n"));
    my $err = do { local $@; eval { $loser->get; 1 } ? undef : $@ };
    T2->like($err, qr/was cancelled/,
        'the raw Future message callers saw instead of the T5/T6 diagnostics');
    my @reported = $wait->failure;
});

T2->subtest('a late ->done on a cancelled loser is discarded (the L26 leak)' => sub {
    my $loser = Future->new;
    my $wait  = Future->wait_any($loser, Future->fail("Timeout\n"));
    my $observed;
    $loser->on_done(sub ($value, @) { $observed = $value });
    my $lived = eval { $loser->done('LATE'); 1 };
    T2->ok($lived, 'a late done on a cancelled future is a silent no-op, not a croak');
    T2->ok(!$loser->is_done, 'the late result never lands');
    T2->is($observed, undef,
        'no continuation observes the late value: the payload is dropped unreaped');
    my @reported = $wait->failure;
});

T2->subtest('->without_cancel shields the underlying from the loser-cancel' => sub {
    my $under  = Future->new;
    my $shield = $under->without_cancel;
    my $wait   = Future->wait_any($shield, Future->fail("Timeout\n"));
    T2->ok($shield->is_cancelled, 'wait_any cancels the shield itself');
    T2->ok(!$under->is_ready, 'the underlying future stays PENDING behind the shield');
    my $observed;
    $under->on_done(sub ($value, @) { $observed = $value });
    $under->done('LATE');
    T2->ok($under->is_done, 'a late completion still lands on the underlying future');
    T2->is($observed, 'LATE',
        'a settle continuation observes the late value: the R33 reaper hook');
    my @reported = $wait->failure;
});

T2->done_testing;
