# ABOUTME: Unit tests for Temporalio::Test::Worker::shutdown (I5, GH #5):
# ABOUTME: a wedged drain must raise, not report a silent clean shutdown.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();
use Temporalio::Test::Worker ();

# A stand-in worker whose run() future is entirely test-controlled. shutdown()
# on the fake settles that same future the way the real worker's finalize
# does: cleanly, with a failure, or (the wedge case) never at all.
package FakeWorker {
    sub new {
        my ($class, %opts) = @_;
        return bless { run_future => undef, on_shutdown => $opts{on_shutdown} }, $class;
    }
    sub run { my $self = shift; return $self->{run_future} = Future->new }
    sub shutdown {
        my $self = shift;
        $self->{on_shutdown}->($self->{run_future}) if $self->{on_shutdown};
    }
}

# wait_any (Future 0.52) CANCELS its losing component the instant the first
# future in the race settles. A cancelled Future is READY but neither done
# nor failed. shutdown()'s race is $run_future vs a timeout_future: an
# unshielded $run_future that loses to the timeout is left cancelled-not-
# failed, so a guard keyed on "die unless $run_future->is_ready" never fires
# and a wedged drain reports a silent, clean shutdown. without_cancel shields
# $run_future from that loser-cancel so its real state (still pending)
# survives the race, and the branch below can key on the ACTUAL state
# instead of the cancelled one wait_any would otherwise leave behind.

T2->subtest('a stalled drain raises the timeout diagnostic, not a silent success' => sub {
    my $loop = IO::Async::Loop->new;
    my $worker = FakeWorker->new(on_shutdown => sub { });   # never settles
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $error = do { local $@; eval { $tw->shutdown(0.2); 1 } ? undef : $@ };
    T2->ok($error, 'shutdown dies on a wedged drain');
    T2->like($error, qr/worker run did not drain within 0\.2s/,
        'the diagnostic is the drain-timeout message, not the loop-failed one')
        or T2->diag($error);
});

T2->subtest('a run future that resolves cleanly: shutdown returns without dying' => sub {
    my $loop = IO::Async::Loop->new;
    my $worker = FakeWorker->new(on_shutdown => sub {
        my $run_future = shift;
        $run_future->done unless $run_future->is_ready;
    });
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $lived = eval { $tw->shutdown(5); 1 };
    T2->ok($lived, 'shutdown returns normally on a clean drain') or T2->diag($@);
});

T2->subtest('a run future that fails: shutdown re-raises the loop-failed diagnostic' => sub {
    my $loop = IO::Async::Loop->new;
    my $worker = FakeWorker->new(on_shutdown => sub {
        my $run_future = shift;
        $run_future->fail("boom\n") unless $run_future->is_ready;
    });
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $error = do { local $@; eval { $tw->shutdown(5); 1 } ? undef : $@ };
    T2->ok($error, 'shutdown dies when the run loop failed during shutdown');
    T2->like($error, qr/worker run loop failed during shutdown: boom/,
        'the diagnostic is the loop-failed message, distinct from the timeout one')
        or T2->diag($error);
});

T2->done_testing;
