# ABOUTME: R90.3 (parity audit client finding 3) once-init pins: concurrent
# ABOUTME: connected_ptr calls on a lazy Connection share ONE deferred connect,
# ABOUTME: a failed connect clears the guard so the next RPC retries, and the
# ABOUTME: pre-connect ptr/update_api_key surfaces raise Runtime.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Temporalio::Client::Connection ();

# A runtime stand-in whose is_shutdown is TRUE so close()/_free_client never
# reaches temporal_core_client_free with our fake pointer values (the same
# liveness guard the real teardown path uses, finding L2).
package FakeRuntime {
    sub new         { bless {}, shift }
    sub is_shutdown { 1 }
}

# Builds a lazy connection around a controllable connect: each invocation
# returns a fresh pending Future the test resolves by hand, and $calls
# counts invocations (the once-init observable).
my sub lazy_fixture () {
    my $calls   = 0;
    my @pending;
    my $connection = Temporalio::Client::Connection->new(
        runtime => FakeRuntime->new,
        connect => sub {
            $calls++;
            my $f = Future->new;
            push @pending, $f;
            return $f;
        },
    );
    return ($connection, \$calls, \@pending);
}

T2->subtest('concurrent first RPCs share the single in-flight connect' => sub {
    my ($connection, $calls, $pending) = lazy_fixture();

    my $first  = $connection->connected_ptr;
    my $second = $connection->connected_ptr;
    T2->is($$calls, 1,
        'two concurrent connected_ptr calls invoked the connect once');
    T2->ok(!$first->is_ready && !$second->is_ready,
        'both callers are parked on the shared in-flight connect');

    $pending->[0]->done(424_242);
    T2->is($first->get,  424_242, 'the first caller got the pointer');
    T2->is($second->get, 424_242, 'the second caller got the same pointer');

    my $third = $connection->connected_ptr;
    T2->is($third->get, 424_242,
        'a later call resolves from the cached pointer');
    T2->is($$calls, 1, 'the connect never ran a second time');
    T2->is($connection->ptr, 424_242,
        'ptr() hands out the pointer once connected');

    $connection->close;
});

T2->subtest('a failed connect clears the guard; the next RPC retries' => sub {
    my ($connection, $calls, $pending) = lazy_fixture();

    my $first  = $connection->connected_ptr;
    my $second = $connection->connected_ptr;
    $pending->[0]->fail("connection refused\n");
    T2->like($first->failure,  qr/connection refused/,
        'the first caller sees the connect failure');
    T2->like($second->failure, qr/connection refused/,
        'the concurrent caller shares the same failure');
    T2->is($$calls, 1, 'the shared failure came from a single connect');

    # Python parity (service.py _connected_client): the lock-guarded
    # "if not self._bridge_client" re-check retries on the next call.
    my $retry = $connection->connected_ptr;
    T2->is($$calls, 2, 'the next RPC re-invokes the connect');
    $pending->[1]->done(313_131);
    T2->is($retry->get, 313_131, 'the retry can then succeed');

    $connection->close;
});

T2->subtest('pre-connect surfaces fail loud on a lazy connection' => sub {
    my ($connection, $calls, $pending) = lazy_fixture();

    my $ptr_error = T2->dies(sub { $connection->ptr });
    T2->ok($ptr_error && $ptr_error->isa('Temporalio::Exception::Runtime'),
        'ptr() before the first RPC raises Runtime')
        or T2->diag($ptr_error);
    T2->like($ptr_error->message, qr/not yet established/,
        'the ptr() message names the lazy not-yet-connected state');

    my $key_error = T2->dies(sub { $connection->update_api_key('token') });
    T2->ok($key_error && $key_error->isa('Temporalio::Exception::Runtime'),
        'update_api_key before the first RPC raises Runtime');
    T2->like($key_error->message, qr/make an RPC first/,
        'the update_api_key message says how to proceed');

    T2->is($$calls, 0, 'neither surface triggered a connect');
    $connection->close;
});

T2->subtest('constructor requires a ptr or a deferred connect' => sub {
    my $error = T2->dies(sub {
        Temporalio::Client::Connection->new(runtime => FakeRuntime->new)
    });
    T2->ok($error && $error->isa('Temporalio::Exception::Argument'),
        'neither ptr nor connect raises Argument')
        or T2->diag($error);
});

T2->subtest('an eager connection is untouched by the lazy machinery' => sub {
    my $connection = Temporalio::Client::Connection->new(
        runtime => FakeRuntime->new,
        ptr     => 555_555,
    );
    T2->is($connection->ptr, 555_555, 'ptr() returns the eager pointer');
    T2->is($connection->connected_ptr->get, 555_555,
        'connected_ptr resolves immediately from the eager pointer');
    $connection->close;
    my $closed = T2->dies(sub { $connection->connected_ptr->get });
    T2->ok($closed && $closed->isa('Temporalio::Exception::Runtime'),
        'connected_ptr on a closed connection raises Runtime');
});

T2->done_testing;
