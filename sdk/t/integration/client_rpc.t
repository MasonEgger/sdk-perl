# ABOUTME: Integration tests for the raw RPC call path (spec sections 7.3/7.5):
# ABOUTME: _rpc_call proto round-trip, NOT_FOUND -> NamespaceNotFound mapping,
# ABOUTME: and the retry flag on TemporalCoreRpcCallOptions.
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
require Temporalio::Core::Proto;

Temporalio::Core::Proto->load;
my $REQUEST_CLASS =
    'Temporalio::Proto::Api::Workflowservice::V1::DescribeNamespaceRequest';
my $RESPONSE_CLASS =
    'Temporalio::Proto::Api::Workflowservice::V1::DescribeNamespaceResponse';

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Await $future on the loop, but never hang the suite: an unresolved future
# dies after $timeout seconds instead of wedging.
sub await_future ($future, $timeout = 30) {
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

my $client = await_future(Temporalio::Client->connect(
    $server->target,
    namespace => 'default',
    runtime   => $runtime,
));

T2->subtest('raw _rpc_call round-trips DescribeNamespace protos' => sub {
    my $response = await_future($client->_rpc_call(
        'DescribeNamespace',
        $REQUEST_CLASS->new({ namespace => 'default' }),
    ));
    T2->isa_ok($response, $RESPONSE_CLASS);
    T2->is($response->namespace_info->name, 'default',
        'response carries the namespace name');
    T2->like($response->namespace_info->id, qr/\S/,
        'response carries a namespace id');
});

T2->subtest('DescribeNamespace on a nonexistent namespace raises NamespaceNotFound' => sub {
    my $err = exception_from(sub {
        await_future($client->_rpc_call(
            'DescribeNamespace',
            $REQUEST_CLASS->new({
                namespace => 'definitely-no-such-namespace',
            }),
        ));
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::NamespaceNotFound'),
        'failure is NamespaceNotFound',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    T2->ok($err && $err->isa('Temporalio::Exception::NotFound'),
        'and isa the NotFound base');
    T2->like("$err", qr/\S/, 'message is informative (non-empty)');
});

T2->subtest('retry flag is set on TemporalCoreRpcCallOptions (spec 7.5)' => sub {
    my @calls;
    my $future;
    {
        no warnings qw(redefine once);
        local *Temporalio::Core::FFI::client_rpc_call = sub {
            push @calls, [@_];
        };
        # async subs run eagerly to the first await, so the spy has already
        # fired by the time _rpc_call returns its pending future.
        $future = $client->_rpc_call(
            'DescribeNamespace',
            $REQUEST_CLASS->new({ namespace => 'default' }),
        );
    }
    T2->is(scalar @calls, 1, 'exactly one FFI call');
    my ($conn_ptr, $options, $user_data, $trampoline) = @{ $calls[0] };
    T2->is($conn_ptr, $client->connection->ptr,
        'called with the live connection ptr');
    T2->isa_ok($options, 'Temporalio::Core::FFI::RpcCallOptions');
    T2->ok($options->retry,
        'retry is set - core, not Perl, applies the RetryConfig');
    T2->is($options->service, 1, 'service is the workflow service');
    T2->is(
        FFI::Platypus::Buffer::buffer_to_scalar(
            $options->rpc_data, $options->rpc_size),
        'DescribeNamespace',
        'rpc name bytes are the RPC name',
    );
    my $sent = $REQUEST_CLASS->decode(
        FFI::Platypus::Buffer::buffer_to_scalar(
            $options->req_data, $options->req_size));
    T2->is($sent->namespace, 'default', 'req bytes are the encoded request');
    T2->is($options->timeout_millis, 0, 'no timeout by default');
    # scalar: record accessors return an empty LIST for a NULL opaque.
    T2->is(scalar $options->cancellation_token, undef, 'no cancellation token');

    $future->cancel;    # the spy swallowed the bridge call; tidy up
});

$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
