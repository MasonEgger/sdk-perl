# ABOUTME: Integration coverage for spec section 31 environment configuration
# ABOUTME: against a live dev server: write a temp temporal.toml pointing at the
# ABOUTME: server, load_client_connect_config, splat into connect, issue one RPC
# ABOUTME: (T-envcfg-int-1). The FFI is the oracle, so this guards the pin.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use File::Temp ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): skip_all when the dev server (temporal CLI) is unavailable.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::EnvConfig::ClientConfig;

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

T2->subtest('load_client_connect_config -> connect -> one RPC (T-envcfg-int-1)' => sub {
    my $target = $server->target;

    # Write a temp temporal.toml whose default profile points at the dev server.
    my $toml = File::Temp->new(SUFFIX => '.toml');
    print {$toml} <<"EOT";
[profile.default]
address = "$target"
namespace = "default"
EOT
    $toml->flush;

    # Load the profile (env disabled for hermeticity) and convert to connect
    # kwargs. The convenience helper combines profile-load + to_connect_config.
    my %connect = %{
        Temporalio::EnvConfig::ClientConfig->load_client_connect_config(
            profile           => 'default',
            config_file       => "$toml",
            disable_env       => 1,
            override_env_vars => {},
        )
    };

    T2->is($connect{target}, $target, 'address loaded as the connect target');
    T2->is($connect{namespace}, 'default', 'namespace loaded from the profile');

    # Splat into connect, deleting target for the positional slot (spec 31.1).
    my $positional = delete $connect{target};
    my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
        Temporalio::Client->connect($positional, %connect, runtime => $runtime);
    });

    # Issue one RPC to prove the loaded config produced a working client. A
    # resolved-or-server-rejected describe both prove the gRPC round-trip; a
    # missing workflow yields a NOT_FOUND rejection (the http_proxy.t idiom).
    my $handle = $client->get_workflow_handle(
        'perl-sdk-envconfig-' . $$ . '-' . int(rand(1_000_000)));
    my $ok = eval { await_future($handle->describe); 1 };
    T2->ok($ok || $@,
        'describe completed (resolved or server-rejected) via env-config client');

    $client->connection->close;
});

# Explicit teardown (P10.0.4-.6): shut the server and runtime down so the
# IO::Async loop drains and the process exits instead of hanging on the live
# runtime queue / dev-server child.
teardown();

T2->done_testing;
