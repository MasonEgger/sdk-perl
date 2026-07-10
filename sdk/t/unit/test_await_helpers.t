# ABOUTME: Unit tests for the Test-helper await paths' Future 0.52 loser-state
# ABOUTME: handling: late-connect reap (R33), timeout diagnostics (R47), wedged retry (R48).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();
use Scalar::Util ();
use Temporalio::Test::Client ();
use Temporalio::Test::Worker ();

# The Future 0.52 loser states driving every case here are pinned by
# t/unit/future_semantics.t (the adapted step-45 probe): wait_any CANCELS
# its losing components; a cancelled future is ready-but-not-failed, its
# ->get croaks "was cancelled", and a late ->done on it is discarded.

my $loop = IO::Async::Loop->new;

# A connection/client pair shaped like Temporalio::Client returns: the
# reaper closes a late-established connection via ->connection->close.
package FakeConnection {
    sub new    { bless { closed => 0 }, shift }
    sub close  { $_[0]{closed}++; return }
    sub closed { $_[0]{closed} }
}

package FakeClient {
    sub new        { bless { connection => FakeConnection->new }, shift }
    sub connection { $_[0]{connection} }
}

# Test::Worker only calls ->run (in ADJUST) and reads the future through
# without_cancel; a never-resolving run future models a healthy worker.
package FakeWorker {
    sub new { bless {}, shift }
    sub run { return Future->new }
}

T2->subtest('R47: await_result timeout surfaces the intended diagnostic' => sub {
    my $tw = Temporalio::Test::Worker->new(
        worker => FakeWorker->new, loop => $loop);
    # Finding T5: the timeout arm CANCELS the result future (ready, not
    # failed), so pre-fix the `unless $future->is_ready` diagnostic branch
    # was dead and ->get croaked the raw "was cancelled".
    my $err = do {
        local $@;
        eval { $tw->await_result(Future->new, 0.2); 1 } ? undef : $@;
    };
    T2->like($err, qr/did not resolve within 0\.2s/,
        'the diagnostic names what was awaited and for how long');
    T2->unlike($err, qr/was cancelled/,
        'the raw Future cancel message never surfaces');
});

T2->subtest('R33: a wedged connect that completes late is closed, not leaked' => sub {
    my $stalled;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    # attempts => 1: the wedged connect exhausts the budget, so the T5/T6
    # diagnostic (not "was cancelled") must surface from the last attempt.
    my $err = do {
        local $@;
        eval {
            Temporalio::Test::Client::connect_with_retry($loop, sub {
                return $stalled = $loop->new_future;
            }, attempts => 1, timeout => 0.2, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->like($err, qr/connect did not resolve within 0\.2s/,
        'the wedged-connect diagnostic surfaces on the last attempt');
    T2->ok(!$stalled->is_cancelled,
        'the abandoned connect future is shielded from the wait_any '
      . 'loser-cancel (a cancelled future would discard the late client)');

    # Finding L26: core completes the connect after the timeout. The reaper
    # must close the late-established connection instead of leaking it.
    my $client = FakeClient->new;
    $stalled->done($client);
    T2->is($client->connection->closed, 1,
        'the late-established connection is closed by the reaper');
    T2->like(join('', @warnings), qr/closing the late connection/,
        'the reap is logged');
});

T2->subtest('R33: a late connect FAILURE is retrieved quietly, nothing to reap' => sub {
    my $stalled;
    local $SIG{__WARN__} = sub { };
    my $err = do {
        local $@;
        eval {
            Temporalio::Test::Client::connect_with_retry($loop, sub {
                return $stalled = $loop->new_future;
            }, attempts => 1, timeout => 0.2, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->like($err, qr/connect did not resolve within/, 'the timeout surfaced');
    # A late failure has no connection to close; the reaper retrieves it so
    # the abandoned future cannot warn as an unreported failure.
    my $lived = eval { $stalled->fail("late connect failure\n"); 1 };
    T2->ok($lived, 'a late failure settles into the reaper without dying');
});

T2->subtest('R48: a wedged first connect is retried, then succeeds' => sub {
    # Finding T6: pre-fix the cancelled loser matched the success branch
    # (is_ready && !is_failed) and ->get croaked, so the wedged-connect
    # retry below never ran.
    my $calls = 0;
    my $stalled;
    local $SIG{__WARN__} = sub { };
    my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
        $calls++;
        return $stalled = $loop->new_future if $calls == 1;
        return Future->done('CLIENT');
    }, attempts => 3, timeout => 0.2, backoff => 0);
    T2->is($client, 'CLIENT', 'the retry connected once the wedge cleared');
    T2->is($calls, 2, 'the wedged first connect was retried exactly once');
});

T2->done_testing;
