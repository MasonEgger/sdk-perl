# ABOUTME: Unit tests for Temporalio::Test::Client::connect_with_retry (P10.0.6):
# ABOUTME: bounded retry around the transient dev-server connect race only.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Scalar::Util ();
use IO::Async::Loop ();
use Temporalio::Test::Client ();
use Temporalio::Exception::RpcError ();
use Temporalio::Exception::Argument ();

my $loop = IO::Async::Loop->new;

# connect_with_retry($loop, $connector, %opts) -> the resolved client. $connector
# is a coderef returning a FRESH Future per call (so a retry re-issues the
# connect). It exists and is callable as a sub.
my $fn = Temporalio::Test::Client->can('connect_with_retry');
T2->ok($fn, 'connect_with_retry is defined');

T2->subtest('returns the client on first success, connecting once' => sub {
    my $calls = 0;
    my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
        $calls++;
        return Future->done('CLIENT');
    });
    T2->is($client, 'CLIENT', 'resolved client is returned');
    T2->is($calls, 1, 'connector called exactly once on success');
});

T2->subtest('retries the dev-server connect race, then succeeds' => sub {
    my $calls = 0;
    my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcError->new(
            message => 'Connection failed: Failed connecting to test server '
                     . 'after 5 seconds, last error: ConnectionRefused'))
            if $calls < 3;
        return Future->done('LATE');
    }, attempts => 5, backoff => 0);
    T2->is($client, 'LATE', 'succeeds once the socket is listening');
    T2->is($calls, 3, 'connector retried until the server accepted');
});

T2->subtest('rethrows after attempts are exhausted' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            Temporalio::Test::Client::connect_with_retry($loop, sub {
                $calls++;
                return Future->fail(Temporalio::Exception::RpcError->new(
                    message => 'tcp connect error: Connection refused'));
            }, attempts => 4, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcError'),
        'the connect RpcError surfaces after the last attempt',
    );
    T2->is($calls, 4, 'connector called exactly attempts times');
});

T2->subtest('does NOT retry a genuine connect failure (TLS mismatch)' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            Temporalio::Test::Client::connect_with_retry($loop, sub {
                $calls++;
                return Future->fail(Temporalio::Exception::RpcError->new(
                    message => 'Connection failed: tls handshake eof'));
            }, attempts => 5, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcError'),
        'a genuine connect failure raises at once',
    );
    T2->is($calls, 1, 'a non-transient connect failure is not retried');
});

T2->subtest('does NOT retry a non-RpcError (Argument: bad PEM)' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            Temporalio::Test::Client::connect_with_retry($loop, sub {
                $calls++;
                return Future->fail(Temporalio::Exception::Argument->new(
                    message => 'ca_cert is not a readable PEM'));
            }, attempts => 5, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'a validation error raises at once',
    );
    T2->is($calls, 1, 'an Argument error is not retried');
});

T2->done_testing;
