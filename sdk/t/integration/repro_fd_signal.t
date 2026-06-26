# ABOUTME: B4 repro (#1): a worker with a SYNC fork-pool activity plus an
# ABOUTME: ephemeral Temporalio::Test::DevServer must tear down cleanly. The
# ABOUTME: full lifecycle — including $server->shutdown — runs in a forked child
# ABOUTME: under a hard timeout; before the fix the IO::Async fork-pool's
# ABOUTME: process-wide SIGCHLD reaper steals sdk-core's dev-server CLI child at
# ABOUTME: $server->shutdown and core SEGVs (exit 139 / signal 11), so the child
# ABOUTME: exits non-zero (RED) instead of 0.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor TEMPORAL_CLI first,
# then scan PATH. No download is ever attempted — offline CI must stay green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Modules are LOADED (FFI symbols attached) in the parent, but NOTHING that
# starts sdk-core's Tokio threads runs here — the runtime is created only inside
# the forked child (SubprocessGuard requires this for a safe fork).
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Activity::FunctionDefinition;
require WfDef::ActivityCaller;
require SubprocessGuard;

# The scenario, run entirely in the forked child. A SYNC activity forces the
# IO::Async::Function fork pool to fork at least one child, which installs the
# process-wide SIGCHLD reaper. The child returns 1 only when the workflow result
# is correct AND the whole teardown (worker, client, dev server, runtime)
# completes without crashing core; the SEGV at $server->shutdown kills the child
# with signal 11, which SubprocessGuard reports as a non-zero exit.
my $child = sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
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

        # A SYNC activity (plain code ref, sync => 1) routes through the
        # IO::Async::Function fork pool — the trigger for the persistent reaper.
        my $activities = [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'SayHello',
                sync => 1,
                code => sub ($name) { return "hello, $name" },
            ),
        ];

        my $task_queue = 'perl-sdk-b4-fd-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::ActivityCaller)],
            activities => $activities,
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        my $handle = $tw->start_workflow_with_retry($client,
            'ActivityCaller', ['Ada'],
            id         => "perl-sdk-b4-fd-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );

        my $result = $tw->await_result($handle->result, 60);
        unless (defined $result && $result eq 'got: hello, Ada') {
            print STDERR "b4 fd: unexpected workflow result: "
                . (defined $result ? $result : 'undef') . "\n";
        }

        # Drain the worker (stops + reaps the fork pool) BEFORE the dev server
        # teardown. The crash under test happens next, at $server->shutdown.
        $tw->shutdown(30);
        $client->connection->close if defined $client;

        # The crash site (#1): sdk-core shuts the ephemeral dev server down and
        # waitpid()s its own `temporal` CLI child. Pre-fix, IO::Async's lingering
        # SIGCHLD reaper reaps that child first and core SEGVs here.
        $server->shutdown;

        $verified = (defined $result && $result eq 'got: hello, Ada') ? 1 : 0;
        1;
    };
    my $scenario_err = $@;

    # Best-effort: if the scenario died BEFORE $server->shutdown, still try to
    # release the server so the CLI child is not orphaned.
    eval { $server->shutdown unless $server->is_shutdown; 1 };
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

my %r = SubprocessGuard::run_guarded($child, timeout => 60);
T2->ok($r{ok},
    'sync fork-pool activity + ephemeral dev server tears down cleanly (no SEGV at $server->shutdown) (#1)')
    or T2->diag($r{reason});

T2->done_testing;
