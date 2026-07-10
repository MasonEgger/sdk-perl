# ABOUTME: Phase 9 Nexus handler-side integration (spec section 26, P9.2): the
# ABOUTME: full sync_success round trip — execute_operation against
# ABOUTME: NexusDef::Handler on the same worker returns "Hello, world!"; history
# ABOUTME: shows NexusOperationScheduled + Completed and NO Started
# ABOUTME: (T-nexus-10/12). Revived by R45 (finding T7): the original called a
# ABOUTME: nonexistent with_worker, passed kwargs to the positional connect, and
# ABOUTME: dereferenced the history iterator as an arrayref; an env gate
# ABOUTME: (TEMPORAL_NEXUS_ENDPOINT) hid the dead code. The endpoint is now
# ABOUTME: self-provisioned via the temporal CLI, so the file runs whenever the
# ABOUTME: CLI is present and skip_alls offline exactly like its siblings.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor TEMPORAL_CLI first,
# then scan PATH. No download is ever attempted. The CLI also provisions the
# Nexus endpoint below, so it is doubly required.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Loaded after the gate so machines without the CLI never compile the FFI stack.
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
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

# `temporal server start-dev` does not enable Nexus by default; the dynamic
# config flag turns the feature on so the endpoint registration below succeeds
# (same provisioning as repro_nexus.t).
my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
    extra_args    => ['--dynamic-config-value', 'system.enableNexus=true'],
);

# Teardown in END so a die mid-file still releases the dev-server CLI child
# (finding T9 / spec R49): DevServer::DESTROY cannot run the event loop, so
# only an END-registered shutdown covers the die path. Enforced by
# xt/devserver_end_teardown.t.
my $tw;
my $client;
my $torn_down = 0;
my sub teardown {
    return if $torn_down;
    $torn_down = 1;
    eval { $tw->shutdown(60) if defined $tw };
    eval { $client->connection->close if defined $client };
    eval { $server->shutdown };
    eval { $runtime->shutdown };
}
# local $? so teardown-time process reaping cannot clobber the exit status
# the die (or Test2) already set for this file.
END { local $?; teardown() }

# Provision a Nexus endpoint on the running dev server via the temporal CLI,
# pointing it at this worker's namespace + task queue. This replaces the old
# TEMPORAL_NEXUS_ENDPOINT/TEMPORAL_NEXUS_TASK_QUEUE env gate whose "operator
# must pre-register an endpoint" requirement kept the file from ever running
# (finding T7).
sub create_nexus_endpoint ($address, $endpoint, $namespace, $task_queue) {
    my @cmd = ($cli, qw(operator nexus endpoint create),
        '--name'               => $endpoint,
        '--target-namespace'   => $namespace,
        '--target-task-queue'  => $task_queue,
        '--address'            => $address,
    );
    my $out = `@cmd 2>&1`;
    my $rc  = $?;
    die "nexus endpoint create failed (rc=$rc): $out\n" if $rc != 0;
    return 1;
}

# connect takes its target POSITIONALLY (Client.pm `connect ($class, $target,
# %options)`); the original passed target_host as a kwarg and died with "Odd
# name/value argument" (finding T7).
$client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $suffix     = "$$-" . int(rand(1_000_000));
my $task_queue = "perl-sdk-nexus-tq-$suffix";
my $endpoint   = "perl-sdk-nexus-ep-$suffix";

create_nexus_endpoint($server->target, $endpoint, 'default', $task_queue);

# Single worker hosting BOTH the caller workflow and the Nexus service (spec
# section 26.5: "execute_operation against My::NexusService on the same
# worker"). Driven by Temporalio::Test::Worker — the with_worker helper the
# original called never existed anywhere in the tree (finding T7).
my $worker = Temporalio::Worker->new(
    client         => $client,
    task_queue     => $task_queue,
    workflows      => ['WfDef::NexusCallerIntegration'],
    nexus_services => ['NexusDef::Handler'],
);
$tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

T2->subtest('same-worker sync Nexus round trip (T-nexus-10/12)' => sub {
    my $handle = $tw->start_workflow_with_retry($client,
        'NexusCallerIntegration', [$endpoint],
        id         => "perl-sdk-nexus-wf-$suffix",
        task_queue => $task_queue,
    );
    my $result = $tw->await_result($handle->result, 60);
    T2->is($result, 'Hello, world!',
        'T-nexus-10: same-worker sync Nexus operation returns the greeting');

    # History: the operation is sync, so Scheduled + Completed with NO
    # Started. fetch_history_events returns an ASYNC ITERATOR (each ->next
    # resolves a Future to one HistoryEvent, undef when exhausted); the
    # original dereferenced it as an arrayref (finding T7).
    my $iter = $handle->fetch_history_events;
    my ($scheduled, $started, $completed) = (0, 0, 0);
    while (1) {
        my $event = $tw->await_result($iter->next, 30);
        last unless defined $event;
        my $which = $event->which_attributes // '';
        $scheduled++ if $which eq 'nexus_operation_scheduled_event_attributes';
        $started++   if $which eq 'nexus_operation_started_event_attributes';
        $completed++ if $which eq 'nexus_operation_completed_event_attributes';
    }
    T2->ok($scheduled >= 1, 'NexusOperationScheduled present');
    T2->ok($completed >= 1, 'NexusOperationCompleted present');
    T2->is($started, 0, 'no NexusOperationStarted for a sync operation');
});

teardown();

T2->done_testing;
