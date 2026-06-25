# ABOUTME: Phase 5 cancellation gate (spec section 11, P5.1): client->workflow
# ABOUTME: cancellation end-to-end against a live dev server. A client cancel
# ABOUTME: propagates promptly: the workflow's pending Futures are cancelled and
# ABOUTME: the workflow ends Cancelled (T-cli-cancel-1 / T-wf-12). An ABANDON-typed
# ABOUTME: activity is left running (no RequestCancelActivity); the workflow still
# ABOUTME: ends Cancelled and no fork-pool child leaks (T-act-9 abandon). The
# ABOUTME: command-level cancel chain (RequestCancelActivity emission + abandon
# ABOUTME: suppression) is proven deterministically in t/replay/completion_outcomes.t.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use Scalar::Util ();
use Time::HiRes ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor TEMPORAL_CLI first,
# then scan PATH (~/.local/bin is on PATH). No download is ever attempted —
# offline CI must stay green.
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
require Temporalio::Activity;
require Temporalio::Activity::FunctionDefinition;
require Temporalio::Exception::WorkflowFailure;
require Temporalio::Exception::Cancelled;

# Fixtures: a workflow that parks on a timer (cancel chain) and one that also
# starts an abandon-typed activity before parking.
require WfDef::CancelChainWorkflow;
require WfDef::AbandonCancelWorkflow;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Await $future on the loop, but never hang the suite.
sub await_future ($future, $timeout = 60) {
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
    return "perl-sdk-cancel-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-cancel-' . $$ . '-' . int(rand(1_000_000));

# The abandon activity: never receives a cancel (abandon emits no
# RequestCancelActivity), so it only ever exits on its own bounded deadline —
# this is the safety net that proves no fork-pool child leaks after the workflow
# stops waiting for it.
my $activities = [
    Temporalio::Activity::FunctionDefinition->new(
        name => 'AbandonActivity',
        code => sub {
            my $end = Time::HiRes::time() + 4;
            Time::HiRes::sleep(0.25) while Time::HiRes::time() < $end;
            return 'abandon-activity-finished';
        },
    ),
];

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::CancelChainWorkflow WfDef::AbandonCancelWorkflow)],
    activities => $activities,
);

# Drive the worker poll loops concurrently with the test body; await_result
# surfaces a worker crash promptly rather than hanging the per-result wait.
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

sub await_with_worker ($future, $timeout = 120) {
    return $tw->await_result($future, $timeout);
}

# Assert a cancelled-workflow result: $handle->result raises WorkflowFailure
# whose cause is Cancelled.
sub assert_cancelled ($handle, $label) {
    my $result;
    my $err = exception_from(sub { $result = await_with_worker($handle->result, 60) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        "$label: cancelled workflow -> WorkflowFailure",
    ) or T2->diag('got: ' . ($err // ('no exception, result=' . ($result // 'undef'))));

    my $cause =
        (Scalar::Util::blessed($err) && $err->can('cause')) ? $err->cause : undef;
    T2->ok(
        Scalar::Util::blessed($cause)
            && $cause->isa('Temporalio::Exception::Cancelled'),
        "$label: WorkflowFailure cause is Cancelled",
    ) or T2->diag('cause: ' . ($cause // 'undef'));
}

T2->subtest('client cancel propagates to the workflow; it ends Cancelled (T-cli-cancel-1 / T-wf-12)' => sub {
    my $handle = $tw->start_workflow_with_retry($client,
        'CancelChainWorkflow',
        [],
        id         => unique_id('chain'),
        task_queue => $task_queue,
    );

    # Let the workflow start and park on its timer.
    await_future($loop->delay_future(after => 1.5));

    # Client cancel -> CancelWorkflow job -> runner cancels the pending timer
    # Future -> Cancelled escapes :Run -> CancelWorkflowExecution.
    await_with_worker($handle->cancel(reason => 'cancel chain test'));

    assert_cancelled($handle, 'cancel chain');
});

T2->subtest('abandon-typed activity is left running; workflow still ends Cancelled (T-act-9 abandon)' => sub {
    my $handle = $tw->start_workflow_with_retry($client,
        'AbandonCancelWorkflow',
        [],
        id         => unique_id('abandon'),
        task_queue => $task_queue,
    );

    # Let the workflow start the abandon activity and park on its timer.
    await_future($loop->delay_future(after => 1.5));

    # Cancel: the timer Future cancellation drives the workflow to Cancelled.
    # The abandon activity Future is also cancelled, but emits NO
    # RequestCancelActivity — the activity is left running (it exits on its own
    # bounded deadline, so no fork-pool child leaks).
    await_with_worker($handle->cancel(reason => 'abandon cancel test'));

    assert_cancelled($handle, 'abandon');
});

# Clean shutdown: initiate worker shutdown (poll loops drain on the ShutDown
# sentinel), await the run future so finalize + free + fork-pool teardown all
# complete, then close the client and stop the server. No orphaned processes —
# the abandoned activity is bounded so its fork-pool child exits on its own.
$tw->shutdown(120);
T2->ok($worker->is_shutdown, 'worker shut down cleanly after run drained');

$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
