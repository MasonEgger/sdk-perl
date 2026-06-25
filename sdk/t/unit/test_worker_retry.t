# ABOUTME: Unit tests for Temporalio::Test::Worker::await_idempotent (P10.0.5):
# ABOUTME: bounded retry around transient RpcTimeout on idempotent reads only.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Scalar::Util ();
use IO::Async::Loop ();
use Temporalio::Test::Worker ();
use Temporalio::Exception::RpcTimeout ();
use Temporalio::Exception::RpcError ();

# A stand-in worker: Test::Worker only calls ->run on it (in ADJUST) and reads
# the resulting future via without_cancel. A never-resolving future keeps the
# "run loop" alive so await_result/await_idempotent only resolve on the body
# future, exactly as a live worker behaves while a query is in flight.
package FakeWorker {
    sub new { bless {}, shift }
    sub run { return Future->new }    # never resolves; never fails
}

my $loop = IO::Async::Loop->new;
my $tw   = Temporalio::Test::Worker->new(worker => FakeWorker->new, loop => $loop);

# await_idempotent exists and re-invokes the producer per attempt.
my $producer = $tw->can('await_idempotent');
T2->ok($producer, 'await_idempotent is defined');

T2->subtest('returns the value on first success, calling the producer once' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->done('ok');
    });
    T2->is($value, 'ok', 'resolved value is returned');
    T2->is($calls, 1, 'producer called exactly once when it succeeds');
});

T2->subtest('retries on a transient RpcTimeout, then succeeds' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcTimeout->new(
            message => 'Timeout expired', status_name => 'DEADLINE_EXCEEDED'))
            if $calls < 3;
        return Future->done('late');
    }, attempts => 3, backoff => 0);
    T2->is($value, 'late', 'succeeds once the timeout clears');
    T2->is($calls, 3, 'producer retried up to the third attempt');
});

T2->subtest('rethrows RpcTimeout after attempts are exhausted' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            $tw->await_idempotent(sub {
                $calls++;
                return Future->fail(Temporalio::Exception::RpcTimeout->new(
                    message => 'Timeout expired'));
            }, attempts => 2, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcTimeout'),
        'the RpcTimeout surfaces after the last attempt',
    );
    T2->is($calls, 2, 'producer called exactly attempts times');
});

T2->subtest('does NOT retry a non-transient RpcError (NOT_FOUND)' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            $tw->await_idempotent(sub {
                $calls++;
                return Future->fail(Temporalio::Exception::RpcError->new(
                    message => 'not found',
                    status_code => 5, status_name => 'NOT_FOUND'));
            }, attempts => 5, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcError')
            && !$err->isa('Temporalio::Exception::RpcTimeout'),
        'a non-transient RpcError is raised immediately',
    );
    T2->is($calls, 1, 'a non-transient error is not retried');
});

# Transient transport hiccups under load surface NOT as RpcTimeout but as a
# bare RpcError: UNAVAILABLE (gRPC 14), or the catch-all with an h2/transport
# message ("h2 protocol error: http2 error", connection reset, broken pipe).
# These are the same load artifact as DEADLINE_EXCEEDED and must retry on an
# idempotent read.
T2->subtest('retries a transient UNAVAILABLE RpcError, then succeeds' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcError->new(
            message => 'unavailable',
            status_code => 14, status_name => 'UNAVAILABLE'))
            if $calls < 2;
        return Future->done('back');
    }, attempts => 3, backoff => 0);
    T2->is($value, 'back', 'succeeds once the transport recovers');
    T2->is($calls, 2, 'UNAVAILABLE was retried');
});

T2->subtest('retries a transient h2/transport-message RpcError' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcError->new(
            message => 'h2 protocol error: http2 error'))
            if $calls < 2;
        return Future->done('back');
    }, attempts => 3, backoff => 0);
    T2->is($value, 'back', 'succeeds once the h2 hiccup clears');
    T2->is($calls, 2, 'an h2 transport error was retried');
});

T2->done_testing;
