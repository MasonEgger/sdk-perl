# ABOUTME: B6 repro (#11): a live caller->handler Nexus round trip on ONE worker.
# ABOUTME: The worker registers a Nexus service + a caller workflow; the caller's
# ABOUTME: execute_operation must resolve with the handler greeting. Today the
# ABOUTME: worker hardcodes enable_nexus => 0 and wires no Nexus poll loop, so the
# ABOUTME: handler never polls Nexus tasks and the caller blocks forever. The whole
# ABOUTME: lifecycle runs in a forked child under a hard timeout (SubprocessGuard):
# ABOUTME: the child exits 0 only on a verified greeting, so the hang reads as a
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
# is also what provisions the Nexus endpoint below, so it is doubly required.
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
require NexusDef::Handler;
require WfDef::NexusCallerIntegration;
require SubprocessGuard;

# Provision a Nexus endpoint on the running dev server via the temporal CLI,
# pointing it at this worker's namespace + task queue. start-dev does not create
# one by default; `system.enableNexus=true` (passed to start-dev below) turns the
# feature on and this registers the endpoint the caller workflow names.
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

# Run the caller->handler round trip end to end in a forked child. Returns 1 only
# when the caller workflow's execute_operation resolves with the handler greeting
# AND teardown completes. With enable_nexus hardcoded 0 (today) the handler never
# polls Nexus tasks, the operation is never serviced, and await_result times out:
# the child returns false (exit 1) — RED.
sub nexus_scenario {
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
            my $task_queue = "perl-sdk-b6-nexus-$suffix";
            my $endpoint   = "perl-sdk-b6-ep-$suffix";

            create_nexus_endpoint(
                $server->target, $endpoint, 'default', $task_queue);

            my $worker = Temporalio::Worker->new(
                client         => $client,
                task_queue     => $task_queue,
                workflows      => ['WfDef::NexusCallerIntegration'],
                nexus_services => ['NexusDef::Handler'],
            );
            $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

            my $handle = $tw->start_workflow_with_retry($client,
                'NexusCallerIntegration', [$endpoint],
                id         => "perl-sdk-b6-nexus-wf-$suffix",
                task_queue => $task_queue,
            );

            my $result = $tw->await_result($handle->result, 45);
            unless (defined $result && $result eq 'Hello, world!') {
                print STDERR "b6 nexus: unexpected result: "
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

# A sync Nexus operation invoked through an in-workflow Nexus client resolves
# with the handler greeting on a single worker that hosts both. The guard's hard
# timeout (90s) covers the documented "blocks forever" failure if the await's own
# 45s timeout is somehow bypassed.
my %r = SubprocessGuard::run_guarded(nexus_scenario(), timeout => 90);
T2->ok($r{ok},
    'same-worker caller->handler Nexus round trip resolves with the greeting (#11)')
    or T2->diag($r{reason});

T2->done_testing;
