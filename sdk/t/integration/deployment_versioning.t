# ABOUTME: Worker deployment-versioning integration test (spec §29.1, P10.5,
# ABOUTME: T-wkrver-4..9). T-wkrver-4 runs a deployment-versioned worker with
# ABOUTME: versioning OFF (routes by task queue, no server-side deployment
# ABOUTME: management needed) and confirms a :VersioningBehavior workflow
# ABOUTME: completes. routing_pinned/auto_upgrade/override/ramp/legacy
# ABOUTME: (T-wkrver-5..9) require set-current-version + ramp + legacy
# ABOUTME: build-id-compat RPCs the SDK does not wrap (spec §29.1 WH-3/WH-4),
# ABOUTME: so they are gated on ENABLE_VERSIONING_TESTS. Skips without a dev
# ABOUTME: server CLI.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): skip_all when the dev server CLI is unavailable.
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
require Temporalio::Worker;
require Temporalio::Worker::DeploymentVersion;
require Temporalio::Worker::DeploymentOptions;
require Temporalio::Test::Worker;

require WfDef::VersionedGreeter;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Explicit teardown so an early failure never wedges the -j4 harness (P7.2
# precedent): always shut the server + runtime down at END.
my $torn_down = 0;
my sub teardown {
    return if $torn_down;
    $torn_down = 1;
    eval { $server->shutdown };
    eval { $runtime->shutdown };
}
END { teardown() }

sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $future->is_ready;
    return $future->get;
}

sub unique ($prefix) {
    return "perl-sdk-ver-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

T2->subtest('T-wkrver-4 routing: a deployment-versioned worker routes + reports behavior' => sub {
    # use_worker_versioning => 0: the worker advertises a deployment version
    # but the server still routes by task queue, so no set-current-version RPC
    # is needed. This exercises the deployment packer + the per-workflow
    # :VersioningBehavior('pinned') reported in the activation completion,
    # end-to-end, without server-side deployment management.
    my $task_queue = unique('deploy');
    my $version    = Temporalio::Worker::DeploymentVersion->new(
        deployment_name => unique('dep'),
        build_id        => '1.0',
    );
    my $deployment_options = Temporalio::Worker::DeploymentOptions->new(
        version               => $version,
        use_worker_versioning => 0,
    );
    my $worker = Temporalio::Worker->new(
        client             => $client,
        task_queue         => $task_queue,
        workflows          => ['WfDef::VersionedGreeter'],
        deployment_options => $deployment_options,
    );
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->start_workflow_with_retry($client,
        'VersionedGreeter',
        ['Alice'],
        id         => unique('wf'),
        task_queue => $task_queue,
        timeout => 60,
    );
    my $result = $tw->await_idempotent(sub { $handle->result });
    T2->is($result, 'Hello, Alice!',
        'deployment-versioned workflow completed (behavior reported, routed)');

    $tw->shutdown(120);
    T2->ok($worker->is_shutdown, 'worker shut down cleanly');
});

# T-wkrver-5 (routing_pinned), T-wkrver-6 (routing_auto_upgrade /
# routing_with_override), T-wkrver-7 (routing_with_ramp), and T-wkrver-8/9
# (legacy build-id compatibility) require raw deployment RPCs the SDK
# intentionally does not wrap: a use_worker_versioning=true worker does not
# receive workflow tasks until set-current-version makes its version current
# (sdk-ruby worker_workflow_versioning_test.rb), and the ramp/legacy paths need
# update/get_worker_build_id_compatibility (spec §29.1 resolved WH-3/WH-4).
# They run only under ENABLE_VERSIONING_TESTS once the harness grows those raw
# calls.
SKIP: {
    T2->skip('T-wkrver-5..9 need ENABLE_VERSIONING_TESTS + raw deployment RPCs', 5)
        unless $ENV{ENABLE_VERSIONING_TESTS};

    T2->fail('T-wkrver-5 routing_pinned not yet implemented');
    T2->fail('T-wkrver-6 routing_auto_upgrade not yet implemented');
    T2->fail('T-wkrver-7 routing_with_ramp not yet implemented');
    T2->fail('T-wkrver-8 legacy build-id set not yet implemented');
    T2->fail('T-wkrver-9 legacy build-id get not yet implemented');
}

$client->connection->close if defined $client;
teardown();

T2->done_testing;
