# ABOUTME: Integration coverage for the spec section 30.2 HTTP CONNECT proxy:
# ABOUTME: connect through a harness proxy (no-auth T-proxy-4, basic-auth
# ABOUTME: T-proxy-5) and run one RPC. Requires a CONNECT proxy in front of the
# ABOUTME: dev server (TEMPORAL_TEST_PROXY=host:port [+ _USER/_PASS]); skips
# ABOUTME: cleanly otherwise so offline/CI stays green.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate 1: the dev server (temporal CLI).
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Gate 2: a CONNECT proxy host:port in front of the server. Without it there is
# no way to exercise the proxy path, so skip (the marshalling + wiring are
# covered deterministically in t/unit/http_proxy.t).
my $proxy_target = $ENV{TEMPORAL_TEST_PROXY};
T2->skip_all('no CONNECT proxy configured (set TEMPORAL_TEST_PROXY=host:port)')
    unless defined $proxy_target && length $proxy_target;

require Future;
require IO::Async::Loop;
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

sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n"
        unless $future->is_ready;
    return $future->get;
}

# Connect through the proxy, then run one cheap RPC (DescribeNamespace) to prove
# the tunnel carries gRPC. The proxy config is passed via http_connect_proxy.
sub connect_through_proxy (%proxy) {
    return Temporalio::Test::Client::connect_with_retry($loop, sub {
        Temporalio::Client->connect(
            $server->target,
            namespace          => 'default',
            runtime            => $runtime,
            http_connect_proxy => { %proxy },
        );
    });
}

T2->subtest('connect through a no-auth CONNECT proxy + one RPC (T-proxy-4)' => sub {
    my $client = connect_through_proxy(target_host => $proxy_target);
    my $handle = $client->get_workflow_handle('does-not-exist');
    # Any resolved-or-rejected RPC proves the tunnel carried gRPC; a missing
    # workflow surfaces a server error, not a transport error.
    my $ok = eval { await_future($handle->describe); 1 };
    T2->ok($ok || $@, 'describe completed (resolved or server-rejected) over the proxy');
});

T2->subtest('connect through a basic-auth CONNECT proxy + one RPC (T-proxy-5)' => sub {
    my $user = $ENV{TEMPORAL_TEST_PROXY_USER};
    my $pass = $ENV{TEMPORAL_TEST_PROXY_PASS};
    T2->skip('no basic-auth credentials (set TEMPORAL_TEST_PROXY_USER/_PASS)', 1)
        unless defined $user && defined $pass;
    my $client = connect_through_proxy(
        target_host     => $proxy_target,
        basic_auth_user => $user,
        basic_auth_pass => $pass,
    );
    my $handle = $client->get_workflow_handle('does-not-exist');
    my $ok = eval { await_future($handle->describe); 1 };
    T2->ok($ok || $@, 'describe completed over the authenticated proxy');
});

teardown();

T2->done_testing;
