# ABOUTME: Integration tests for Temporalio::Client->connect (spec section
# ABOUTME: 7.3, T-cli-connect-1..4): live connect, TLS mismatch, bad PEM,
# ABOUTME: update_api_key reaching the FFI call.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use Scalar::Util ();

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor the TEMPORAL_CLI
# env override first, then scan PATH. No download is ever attempted here —
# offline CI must stay green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Loaded after the gate so machines without the CLI never compile the
# FFI-heavy stack.
require Future;
require IO::Async::Loop;
require FFI::Platypus::Buffer;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Teardown in END so a die mid-file still releases the dev-server CLI child
# (finding T9 / spec R49): DevServer::DESTROY cannot run the event loop, so
# only an END-registered shutdown covers the die path. Enforced by
# xt/devserver_end_teardown.t.
my $torn_down = 0;
my sub teardown {
    return if $torn_down;
    $torn_down = 1;
    eval { $server->shutdown };
    eval { $runtime->shutdown };
}
# local $? so teardown-time process reaping cannot clobber the exit status
# the die (or Test2) already set for this file.
END { local $?; teardown() }

# Await $future on the loop, but never hang the suite: an unresolved future
# dies after $timeout seconds instead of wedging.
sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n"
        unless $future->is_ready;
    return $future->get;
}

# Captures the exception a code block dies with; returns it (or undef).
sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

my $client;

T2->subtest('connect succeeds with expected namespace + identity (T-cli-connect-1)' => sub {
    $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
        Temporalio::Client->connect(
            $server->target,
            namespace => 'default',
            runtime   => $runtime,
        );
    });
    T2->isa_ok($client, 'Temporalio::Client');
    T2->is($client->namespace, 'default', 'namespace is default');
    T2->is($client->identity, Temporalio::Client->default_identity,
        'identity defaults to pid@hostname');
    T2->like($client->identity, qr/^\d+@\S+$/, 'identity shape');
    T2->isa_ok($client->connection, 'Temporalio::Client::Connection');
    T2->ok(defined $client->connection->ptr, 'connection holds a live ptr');
    T2->isa_ok($client->data_converter, 'Temporalio::Converter::Data');
});

T2->subtest('TLS against the non-TLS dev server raises RpcError (T-cli-connect-2)' => sub {
    my $err = exception_from(sub {
        # Core retries UNAVAILABLE for up to max_elapsed_time (10s default);
        # the await timeout just keeps a wedged bridge from hanging the suite.
        await_future(
            Temporalio::Client->connect(
                $server->target,
                tls     => 1,
                runtime => $runtime,
            ),
            60,
        );
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcError'),
        'failure is an RpcError',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/\S/, 'message is informative (non-empty)');
    T2->like($err->message, qr/Connection failed/i,
        'message carries the bridge connect failure');
});

T2->subtest('bad PEM raises Argument before any RPC (T-cli-connect-3)' => sub {
    my $err = exception_from(sub {
        await_future(
            Temporalio::Client->connect(
                $server->target,
                tls     => { ca_cert => 'definitely/not-a-pem-or-a-readable-file' },
                runtime => $runtime,
            ),
            5,    # validation fails immediately; no RPC ever starts
        );
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'failure is an Argument exception',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/ca_cert/, 'message names the bad field');
});

T2->subtest('update_api_key reaches the FFI call (T-cli-connect-4)' => sub {
    my @calls;
    {
        no warnings qw(redefine once);
        local *Temporalio::Core::FFI::client_update_api_key = sub {
            push @calls, [@_];
        };
        $client->update_api_key('B');
    }
    T2->is(scalar @calls, 1, 'exactly one FFI call');
    my ($conn_ptr, $key_ref) = @{ $calls[0] };
    T2->is($conn_ptr, $client->connection->ptr,
        'called with the live connection ptr');
    T2->isa_ok($key_ref, 'Temporalio::Core::FFI::ByteArrayRef');
    T2->is(
        FFI::Platypus::Buffer::buffer_to_scalar(
            $key_ref->data, $key_ref->size),
        'B',
        'api key bytes are the new token',
    );

    # And once for real, to exercise the by-value record across the ABI.
    my $real = eval { $client->update_api_key('rotated-token'); 1 };
    T2->ok($real, 'real update_api_key call succeeds') or T2->diag($@);
});

$client->connection->close if defined $client;
teardown();

T2->done_testing;
