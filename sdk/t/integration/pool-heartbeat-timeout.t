# ABOUTME: Spec R18 (finding L13) against a live dev server: a compliant
# ABOUTME: long-running SYNC (fork-pool) activity that heartbeats faster than
# ABOUTME: its heartbeat_timeout must NOT hit that timeout. Pre-fix the pool
# ABOUTME: relayed heartbeats only after the body returned, so the server saw
# ABOUTME: zero heartbeats during the ~5s body and failed the activity at the
# ABOUTME: 2s heartbeat_timeout; with maximum_attempts 1 the workflow failed.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. Honor TEMPORAL_CLI first, then scan PATH. No download attempted.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

require Future;
require IO::Async::Loop;
require Time::HiRes;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Test::Worker;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Activity;
require Temporalio::Activity::FunctionDefinition;

require WfDef::HeartbeatTimeoutCaller;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Teardown in END so a die mid-test still releases the dev-server CLI child
# (updates.t:176-179 precedent).
my $client;
END {
    if (defined $server) {
        eval { $client->connection->close if defined $client; 1 };
        eval { $server->shutdown unless $server->is_shutdown; 1 };
        eval { $runtime->shutdown if defined $runtime; 1 };
    }
}

$client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

# A COMPLIANT long-running sync activity: ~5s of work in a forked pool child,
# heartbeating every ~0.5s — comfortably inside the workflow's 2s
# heartbeat_timeout as long as the heartbeats reach the server WHILE the body
# runs (spec R18). sync => 1 routes it through the Activity::Pool fork pool,
# the code path under test.
my $activities = [
    Temporalio::Activity::FunctionDefinition->new(
        name => 'SlowButHeartbeating',
        sync => 1,
        code => sub () {
            for my $tick (1 .. 10) {
                Temporalio::Activity::heartbeat("tick $tick");
                Time::HiRes::sleep(0.5);
            }
            return 'survived';
        },
    ),
];

my $task_queue = 'perl-sdk-r18-hb-' . $$ . '-' . int(rand(1_000_000));
my $worker     = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::HeartbeatTimeoutCaller)],
    activities => $activities,
);
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

my $handle = $tw->start_workflow_with_retry($client,
    'HeartbeatTimeoutCaller', [],
    id         => "perl-sdk-r18-hb-$$-" . int(rand(1_000_000)),
    task_queue => $task_queue,
);

# Pre-fix this throws WorkflowFailure -> Activity -> Timeout(heartbeat):
# the server registered no heartbeat during the running body (finding L13).
my $result = eval { $tw->await_idempotent(sub { $handle->result }) };
my $error  = $@;
T2->is($result, 'got: survived',
    'compliant heartbeating sync activity does NOT hit heartbeat_timeout'
        . ' (spec R18; pre-fix: heartbeats relayed only after the body'
        . ' returned)')
    or T2->diag("workflow failed: $error");

$tw->shutdown(120);

T2->done_testing;
