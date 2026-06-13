# ABOUTME: Phase 3 acceptance gate (spec section 11, P3.9): the first full
# ABOUTME: client+worker+workflow+activity round trip against a live dev server —
# ABOUTME: greeting (activity), timer (sleep), and activity-failure propagation.
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
# then scan PATH. No download is ever attempted — offline CI must stay green.
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
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Activity::FunctionDefinition;
require Temporalio::Exception::Application;

# Fixtures: a greeting workflow + SayHello activity, a sleeper workflow, and a
# failer workflow + FailingActivity.
require WfDef::E2EGreeting;
require WfDef::E2ESleeper;
require WfDef::E2EFailer;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Await $future on the loop, but never hang the suite.
sub await_future ($future, $timeout = 30) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n"
        unless $future->is_ready;
    return $future->get;
}

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub unique_id ($prefix) {
    return "perl-sdk-e2e-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = await_future(Temporalio::Client->connect(
    $server->target,
    namespace => 'default',
    runtime   => $runtime,
));

my $task_queue = 'perl-sdk-e2e-' . $$ . '-' . int(rand(1_000_000));

# The activity set, shared by all three cases on the one worker/task-queue.
#  - SayHello($name)  -> "Hello, $name!"
#  - FailingActivity  -> throws an Application failure with a stable type.
my $activities = [
    Temporalio::Activity::FunctionDefinition->new(
        name => 'SayHello',
        code => sub ($name) { return "Hello, $name!" },
    ),
    Temporalio::Activity::FunctionDefinition->new(
        name => 'FailingActivity',
        code => sub {
            Temporalio::Exception::Application->throw(
                message => 'activity boom',
                type    => 'BoomError',
            );
        },
    ),
];

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::E2EGreeting WfDef::E2ESleeper WfDef::E2EFailer)],
    activities => $activities,
);

# Drive the worker's poll loops concurrently with the test body (the helper
# starts the run loops on construction). await_result awaits each workflow's
# result while the worker runs, surfacing a worker-loop crash promptly rather
# than hanging the per-result wait.
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

sub await_with_worker ($future, $timeout = 60) {
    return $tw->await_result($future, $timeout);
}

T2->subtest('greeting workflow calls an activity and returns its result (T-cli-result-1)' => sub {
    my $handle = await_with_worker($client->start_workflow(
        'E2EGreeting',
        ['Alice'],
        id         => unique_id('greeting'),
        task_queue => $task_queue,
    ));
    my $result = await_with_worker($handle->result, 60);
    T2->is($result, 'Hello, Alice!',
        'greeting workflow returned the activity result');
});

T2->subtest('timer workflow sleeps and completes (timer path end-to-end)' => sub {
    my $handle = await_with_worker($client->start_workflow(
        'E2ESleeper',
        [1],
        id         => unique_id('sleeper'),
        task_queue => $task_queue,
    ));
    my $result = await_with_worker($handle->result, 60);
    T2->is($result, 'awake', 'sleeper workflow progressed past its timer');
});

T2->subtest('activity failure propagates as WorkflowFailure -> Activity -> Application (T-wf-15b end-to-end)' => sub {
    my $handle = await_with_worker($client->start_workflow(
        'E2EFailer',
        [],
        id         => unique_id('failer'),
        task_queue => $task_queue,
    ));
    my $err = exception_from(sub { await_with_worker($handle->result, 60) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        'failed workflow -> WorkflowFailure',
    ) or T2->diag('got: ' . ($err // 'no exception'));

    my $activity_cause =
        (Scalar::Util::blessed($err) && $err->can('cause')) ? $err->cause : undef;
    T2->ok(
        Scalar::Util::blessed($activity_cause)
            && $activity_cause->isa('Temporalio::Exception::Activity'),
        'cause is an Activity failure',
    ) or T2->diag('cause: ' . ($activity_cause // 'undef'));

    my $app_cause =
        (Scalar::Util::blessed($activity_cause) && $activity_cause->can('cause'))
        ? $activity_cause->cause : undef;
    T2->ok(
        Scalar::Util::blessed($app_cause)
            && $app_cause->isa('Temporalio::Exception::Application'),
        'inner cause is an Application failure',
    ) or T2->diag('inner cause: ' . ($app_cause // 'undef'));
    T2->is($app_cause->type, 'BoomError', 'Application failure carries the type')
        if Scalar::Util::blessed($app_cause) && $app_cause->can('type');
});

# Clean shutdown: initiate worker shutdown (poll loops drain on the ShutDown
# sentinel), await the run future so finalize + free + fork-pool teardown all
# complete, then close the client and stop the server. No orphaned processes.
$tw->shutdown(60);
T2->ok($worker->is_shutdown, 'worker shut down cleanly after run drained');

$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
