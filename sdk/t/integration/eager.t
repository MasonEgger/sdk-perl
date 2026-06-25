# ABOUTME: Phase 7 eager start (spec section 23, P7.3) against a live dev server:
# ABOUTME: detect-only eager workflow start (T-eager-2, skips when the server
# ABOUTME: returns no eager task) and the eager-activity decline path — a
# ABOUTME: no_remote_activities worker lets a scheduled activity time out
# ABOUTME: SCHEDULE_TO_START (T-eager-5).
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
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Activity::FunctionDefinition;
require Temporalio::Exception::Timeout;
require Temporalio::Exception::WorkflowFailure;

require WfDef::E2EGreeting;
require WfDef::EagerActivityWorkflow;

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

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub unique_id ($prefix) {
    return "perl-sdk-eager-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-eager-' . $$ . '-' . int(rand(1_000_000));

# A SayHello activity reused by both subtests' workers.
my $say_hello = Temporalio::Activity::FunctionDefinition->new(
    name => 'SayHello',
    code => sub ($name = 'World') { "Hello, $name!" },
);

# ---------------------------------------------------------------------------
# T-eager-2: request_eager_start against the live server. Eager workflow start
# is detect-only — the lang layer never routes the embedded task, so the
# workflow only actually starts when a worker is polling the queue. We assert
# the request round-trips and the workflow completes; eagerly_started is
# reported off the response and the subtest SKIPS the eager assertion when the
# server returned no eager task (the dev server has eager start disabled).
# ---------------------------------------------------------------------------
T2->subtest('request_eager_start workflow completes; eagerly_started reported (T-eager-2)' => sub {
    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => $task_queue,
        workflows  => [qw(WfDef::E2EGreeting)],
        activities => [$say_hello],
    );
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->start_workflow_with_retry($client,
        'E2EGreeting',
        ['Alice'],
        id                  => unique_id('e2e'),
        task_queue          => $task_queue,
        request_eager_start => 1,
    );

    T2->ok(defined $handle->eagerly_started,
        'eagerly_started is a defined boolean off the start response');
    if ($handle->eagerly_started) {
        T2->pass('server returned an eager workflow task (T-eager-2)');
    }
    else {
        T2->note('server returned no eager task (eager start disabled) — '
            . 'eager assertion skipped per spec section 23.1');
    }

    my $result = $tw->await_idempotent(sub { $handle->result });
    T2->is($result, 'Hello, Alice!', 'eager-requested workflow completed normally');

    $tw->shutdown(120);
});

# ---------------------------------------------------------------------------
# T-eager-5: a worker with no_remote_activities => 1 has no remote activity
# poller. A workflow that schedules an activity with a short schedule_to_start
# timeout therefore never gets the task picked up, and the activity fails
# SCHEDULE_TO_START. The failure propagates as WorkflowFailure -> Activity ->
# Timeout(schedule_to_start).
# ---------------------------------------------------------------------------
T2->subtest('no_remote_activities -> activity times out SCHEDULE_TO_START (T-eager-5)' => sub {
    my $no_remote_tq = $task_queue . '-noremote';
    my $worker = Temporalio::Worker->new(
        client               => $client,
        task_queue           => $no_remote_tq,
        workflows            => [qw(WfDef::EagerActivityWorkflow)],
        activities           => [$say_hello],
        no_remote_activities => 1,
    );
    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->start_workflow_with_retry($client,
        'EagerActivityWorkflow',
        ['Bob'],
        id         => unique_id('noremote'),
        task_queue => $no_remote_tq,
    );

    my $err = exception_from(sub { $tw->await_idempotent(sub { $handle->result }) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        'no-remote-activity workflow fails (WorkflowFailure)',
    ) or T2->diag('got: ' . ($err // 'no exception'));

    # Drill to the timeout cause: WorkflowFailure -> Activity -> Timeout.
    my $cause = (Scalar::Util::blessed($err) && $err->can('cause'))
        ? $err->cause : undef;
    my $timeout = $cause;
    while (Scalar::Util::blessed($timeout)
        && !$timeout->isa('Temporalio::Exception::Timeout')
        && $timeout->can('cause'))
    {
        $timeout = $timeout->cause;
    }
    T2->ok(
        Scalar::Util::blessed($timeout)
            && $timeout->isa('Temporalio::Exception::Timeout'),
        'failure cause chain reaches a Timeout',
    ) or T2->diag('cause chain: ' . ($cause // 'undef'));
    T2->is($timeout->timeout_type, 'schedule_to_start',
        'timeout type is schedule_to_start (T-eager-5)')
        if Scalar::Util::blessed($timeout)
            && $timeout->isa('Temporalio::Exception::Timeout');

    $tw->shutdown(120);
});

# Clean shutdown: close the client and stop the dev server + runtime. The
# per-subtest workers are already drained; skipping this leaks the dev-server
# child and wedges a parallel `prove`.
$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
