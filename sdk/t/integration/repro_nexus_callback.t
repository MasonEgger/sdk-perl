# ABOUTME: B13 repro (#11): a live :WorkflowRunOperation caller->handler round
# ABOUTME: trip on ONE worker. The caller workflow invokes an async (workflow-
# ABOUTME: backed) Nexus operation; the handler starts a backing workflow through
# ABOUTME: the operation context's client. The caller's execute_operation must
# ABOUTME: resolve with the BACKING workflow's result — which only happens if the
# ABOUTME: backing-workflow start carried the Nexus async completion callback.
# ABOUTME: Before B13's fix the start had completionCallbacks:null, so the backing
# ABOUTME: workflow completed but the caller's operation parked forever (server:
# ABOUTME: `Pending Nexus Operations: 1`). The whole lifecycle runs in a forked
# ABOUTME: child under a hard timeout (SubprocessGuard): a park reads as a
# ABOUTME: non-zero exit (RED) instead of wedging the suite.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. Honor TEMPORAL_CLI first, then scan PATH; never download. The CLI
# also provisions the Nexus endpoint below, so it is doubly required.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Modules LOADED (FFI symbols attached) in the parent; NOTHING that starts
# sdk-core's Tokio threads runs here. The runtime is created only in the child.
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
require NexusDef::WorkflowRunHandler;
require WfDef::NexusBackingWorkflow;
require WfDef::NexusWorkflowRunCaller;
require SubprocessGuard;

# Provision a Nexus endpoint on the running dev server via the temporal CLI,
# pointing it at this worker's namespace + task queue.
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

# Run the WorkflowRunOperation round trip end to end in a forked child. Returns 1
# only when the caller workflow's execute_operation resolves with the backing
# workflow's greeting AND teardown completes. Without the async completion
# callback (today) the server never notifies the caller, the operation parks, and
# await_result times out: the child returns false (exit 1) — RED.
sub nexus_callback_scenario {
    return sub {
        my $loop    = IO::Async::Loop->new;
        my $runtime = Temporalio::Runtime->new(loop => $loop);

        my $server = Temporalio::Test::DevServer->start(
            runtime       => $runtime,
            existing_path => $cli,
            log_level     => 'warn',
            extra_args    => ['--dynamic-config-value', 'system.enableNexus=true'],
        );

        my $verified = 0;
        my $tw;
        my $client;

        my $ok = eval {
            $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
                Temporalio::Client->connect(
                    $server->target,
                    namespace => 'default',
                    runtime   => $runtime,
                );
            });

            my $suffix     = "$$-" . int(rand(1_000_000));
            my $task_queue = "perl-sdk-b13-nexus-$suffix";
            my $endpoint   = "perl-sdk-b13-ep-$suffix";

            create_nexus_endpoint(
                $server->target, $endpoint, 'default', $task_queue);

            my $worker = Temporalio::Worker->new(
                client         => $client,
                task_queue     => $task_queue,
                workflows      => [
                    'WfDef::NexusWorkflowRunCaller',
                    'WfDef::NexusBackingWorkflow',
                ],
                nexus_services => ['NexusDef::WorkflowRunHandler'],
            );
            $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

            my $handle = $tw->start_workflow_with_retry($client,
                'NexusWorkflowRunCaller', [$endpoint],
                id         => "perl-sdk-b13-nexus-wf-$suffix",
                task_queue => $task_queue,
            );

            my $result = $tw->await_result($handle->result, 60);
            unless (defined $result && $result eq 'Hello, world!') {
                print STDERR "b13 nexus: unexpected result: "
                    . (defined $result ? $result : 'undef')
                    . " (wanted 'Hello, world!')\n";
            }

            $tw->shutdown(30);
            $client->connection->close if defined $client;
            $server->shutdown;

            $verified = (defined $result && $result eq 'Hello, world!') ? 1 : 0;
            1;
        };
        my $scenario_err = $@;

        eval { $server->shutdown unless $server->is_shutdown; 1 };
        $runtime->shutdown;

        die $scenario_err if !$ok && $scenario_err;
        return $verified;
    };
}

# An async :WorkflowRunOperation invoked through an in-workflow Nexus client
# resolves with the BACKING workflow's result on a single worker that hosts the
# caller, the handler, and the backing workflow. The guard's hard timeout (110s)
# covers the documented "parks forever" failure if the await's own 60s timeout is
# somehow bypassed.
my %r = SubprocessGuard::run_guarded(nexus_callback_scenario(), timeout => 110);
T2->ok($r{ok},
    'WorkflowRunOperation caller->handler round trip resolves with the backing '
    . 'workflow result (#11)')
    or T2->diag($r{reason});

T2->done_testing;
