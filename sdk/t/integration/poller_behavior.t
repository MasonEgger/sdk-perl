# ABOUTME: Autoscaling-poller integration smoke (spec §29.3, P10.7, T-poller-5):
# ABOUTME: a worker built with autoscaling workflow + activity pollers connects,
# ABOUTME: polls, and completes a trivial workflow (proves core accepts the
# ABOUTME: packed two-pointer struct; no scaling assertion is possible offline).
# ABOUTME: Skips without a dev server CLI; explicit teardown (P7.2 precedent).
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
require Temporalio::Worker::PollerBehavior::SimpleMaximum;
require Temporalio::Worker::PollerBehavior::Autoscaling;
require Temporalio::Test::Worker;

require WfDef::Constant;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

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
    return "perl-sdk-poller-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

T2->subtest('T-poller-5 autoscaling pollers drive a worker to completion' => sub {
    my $task_queue = unique('autoscale');

    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => $task_queue,
        workflows  => ['WfDef::Constant'],
        # Autoscaling for workflow tasks (minimum 1, scales up); SimpleMaximum
        # for activity tasks. Both pack into the two-pointer struct core must
        # accept.
        workflow_task_poller_behavior =>
            Temporalio::Worker::PollerBehavior::Autoscaling->new(
                minimum => 1, maximum => 10, initial => 2),
        activity_task_poller_behavior =>
            Temporalio::Worker::PollerBehavior::SimpleMaximum->new(maximum => 3),
    );
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->start_workflow_with_retry($client,
        'Constant',
        ['Poller'],
        id         => unique('wf'),
        task_queue => $task_queue,
        timeout => 60,
    );
    my $result = $tw->await_idempotent(sub { $handle->result });
    T2->is($result, 'Hello, Poller!',
        'workflow completed with autoscaling workflow pollers');

    $tw->shutdown(120);
    T2->ok($worker->is_shutdown, 'worker shut down cleanly');
});

$client->connection->close if defined $client;
teardown();

T2->done_testing;
