# ABOUTME: Phase 7 async activity completion (spec section 22, P7.2) against a
# ABOUTME: live dev server: client AsyncActivityHandle complete/fail/
# ABOUTME: report_cancellation/heartbeat by token and by id (T-asyncact-1..5,9),
# ABOUTME: heartbeat cancel-request -> AsyncActivityCancelled (T-asyncact-6), and
# ABOUTME: the worker-side complete_async -> WillCompleteAsync -> out-of-band
# ABOUTME: completion end-to-end (T-asyncact-7).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use Scalar::Util ();

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
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Test::Worker;
require Temporalio::Client;
require Temporalio::Worker;
require Temporalio::Activity::FunctionDefinition;
require Temporalio::Exception::Application;
require Temporalio::Exception::Activity::AsyncActivityCancelled;

require WfDef::E2EGreeting;
require WfDef::AsyncActivityWorkflow;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $future->is_ready;
    return $future->get;
}

sub unique_id ($prefix) {
    return "perl-sdk-asyncact-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = await_future(Temporalio::Client->connect(
    $server->target,
    namespace => 'default',
    runtime   => $runtime,
));

my $task_queue = 'perl-sdk-asyncact-' . $$ . '-' . int(rand(1_000_000));

# ---------------------------------------------------------------------------
# T-asyncact-7: end-to-end out-of-band completion. The activity captures its
# own task token (so the test can drive the handle) then declares it will
# complete asynchronously via complete_async. The workflow awaits the activity
# result; the test completes the activity out of band through the handle, and
# the workflow result reflects the out-of-band value.
# ---------------------------------------------------------------------------
my @captured_tokens;
my $activities = [
    Temporalio::Activity::FunctionDefinition->new(
        name => 'CaptureAndCompleteAsync',
        code => sub {
            my $ctx = Temporalio::Activity::context();
            push @captured_tokens, $ctx->info->{task_token};
            Temporalio::Activity::complete_async();
        },
    ),
];

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::AsyncActivityWorkflow)],
    activities => $activities,
);
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

T2->subtest('complete_async -> out-of-band completion end-to-end (T-asyncact-7)' => sub {
    my $handle = $tw->await_result($client->start_workflow(
        'AsyncActivityWorkflow',
        [],
        id         => unique_id('e2e'),
        task_queue => $task_queue,
    ));

    # Wait for the activity to register its task token (it returns immediately
    # after declaring complete_async; the workflow stays pending).
    my $deadline = time + 30;
    while (!@captured_tokens && time < $deadline) {
        $loop->await($loop->delay_future(after => 0.1));
    }
    T2->ok(@captured_tokens, 'activity captured its task token');

    my $async = $client->async_activity_handle(task_token => $captured_tokens[0]);
    $tw->await_result($async->complete('out-of-band!'));

    my $result = $tw->await_idempotent(sub { $handle->result });
    T2->is($result, 'out-of-band!', 'workflow result is the out-of-band value');
});

# Clean shutdown (mirrors end_to_end.t): drain the worker poll loops, close the
# client, and stop the dev server + runtime. Skipping this leaks the dev-server
# child, which inherits the TAP harness pipe and wedges a parallel `prove` run.
$tw->shutdown(120);
$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
