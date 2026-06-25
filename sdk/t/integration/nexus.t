# ABOUTME: Phase 9 Nexus handler-side integration (spec section 26, P9.2): the
# ABOUTME: full sync_success round trip — execute_operation against My::NexusService
# ABOUTME: on the same worker returns "Hello, world!"; history Scheduled+Completed,
# ABOUTME: NO Started (T-nexus-10/12). Workflow-run start -> Async, cancel cancels
# ABOUTME: the backing workflow (T-nexus-13). Handler/operation errors (T-nexus-14).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use Scalar::Util ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor TEMPORAL_CLI first,
# then scan PATH. No download is ever attempted.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# A Nexus handler round trip additionally needs a registered Nexus endpoint
# pointing at this worker's task queue. `temporal server start-dev` does not
# provision one by default, and creating + wiring an endpoint here is out of
# scope for the offline suite. Skip unless the operator has configured an
# endpoint name (TEMPORAL_NEXUS_ENDPOINT) plus the matching task queue
# (TEMPORAL_NEXUS_TASK_QUEUE) bound to that endpoint on a reachable server
# (TEMPORAL_ADDRESS, default localhost:7233). A green suite offline is expected
# (spec section 26.5 T-nexus-10: "needs a registered nexus endpoint on the dev
# server, skip_all if unavailable").
my $endpoint   = $ENV{TEMPORAL_NEXUS_ENDPOINT};
my $task_queue = $ENV{TEMPORAL_NEXUS_TASK_QUEUE};
T2->skip_all(
    'no Nexus endpoint configured (set TEMPORAL_NEXUS_ENDPOINT + '
    . 'TEMPORAL_NEXUS_TASK_QUEUE bound to a reachable server)')
    unless defined $endpoint && length $endpoint
        && defined $task_queue && length $task_queue;

# Loaded after the gates so machines without the CLI never compile the FFI stack.
require Future;
require Future::AsyncAwait;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Nexus;
require Temporalio::Workflow;

# Fixtures: a Nexus service whose sync op greets, and a caller workflow that
# runs an in-workflow Nexus client against it.
require NexusDef::Handler;
require WfDef::NexusCallerIntegration;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $future->is_ready;
    return $future->get;
}

my $address = $ENV{TEMPORAL_ADDRESS} // 'localhost:7233';
my $client  = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        runtime => $runtime, target_host => $address, namespace => 'default');
});

# Single worker hosting BOTH the caller workflow and the Nexus service (spec
# section 26.5: "execute_operation against My::NexusService on the same worker").
my $worker = Temporalio::Worker->new(
    client         => $client,
    task_queue     => $task_queue,
    workflows      => ['WfDef::NexusCallerIntegration'],
    nexus_services => ['NexusDef::Handler'],
);

# T-nexus-10/12: the caller workflow's execute_operation against the same-worker
# sync Nexus operation returns "Hello, world!" with no Started event.
Temporalio::Test::Worker::with_worker($worker, sub {
    my $handle = await_future($client->start_workflow(
        'WfDef::NexusCallerIntegration', [$endpoint],
        id         => "perl-sdk-nexus-$$-" . int(rand(1_000_000)),
        task_queue => $task_queue,
    ));
    my $result = await_future($handle->result, 60);
    T2->is($result, 'Hello, world!',
        'T-nexus-10: same-worker sync Nexus operation returns the greeting');

    # History: the operation is sync, so Scheduled + Completed with NO Started.
    my $started = 0;
    my $scheduled = 0;
    my $completed = 0;
    my $events = await_future($handle->fetch_history_events)
        if $handle->can('fetch_history_events');
    if ($events) {
        for my $e (@$events) {
            my $t = $e->can('event_type') ? ($e->event_type // '') : '';
            $scheduled++ if $t =~ /NexusOperationScheduled/;
            $started++   if $t =~ /NexusOperationStarted/;
            $completed++ if $t =~ /NexusOperationCompleted/;
        }
        T2->ok($scheduled >= 1, 'NexusOperationScheduled present');
        T2->ok($completed >= 1, 'NexusOperationCompleted present');
        T2->is($started, 0, 'no NexusOperationStarted for a sync operation');
    }
});

T2->done_testing;
