# ABOUTME: Phase 4 acceptance gate (spec section 11, P4.4): client signal/query
# ABOUTME: end-to-end against a live dev server — $handle->signal drives a Perl
# ABOUTME: worker's :Signal handler, $handle->query reads :Query state back, and
# ABOUTME: a reject_condition query against a terminated workflow raises rejected.
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
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Exception::QueryRejected;

# Fixture: a workflow that waits for a setName signal, exposes a currentName
# query, then greets and completes.
require WfDef::SignalQueryGreeter;

# reject_condition enum value (temporal/api/enums/v1/query.proto): NOT_OPEN = 2.
# Verified against sdk-ruby workflow_query_reject_condition.rb
# (NOT_OPEN = QUERY_REJECT_CONDITION_NOT_OPEN) and sdk-python _impl.py:433
# (req.query_reject_condition = <enum int>).
use constant QUERY_REJECT_NOT_OPEN => 2;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Teardown in END so a die mid-file still releases the dev-server CLI child
# (finding T9 / spec R49): DevServer::DESTROY cannot run the event loop, so
# only an END-registered shutdown covers the die path. Enforced by
# xt/devserver_end_teardown.t.
my $torn_down = 0;
my sub teardown {
    return if $torn_down;
    $torn_down = 1;
    eval { $server->shutdown };
    eval { $runtime->shutdown };
}
# local $? so teardown-time process reaping cannot clobber the exit status
# the die (or Test2) already set for this file.
END { local $?; teardown() }

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
    return "perl-sdk-sigq-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-sigq-' . $$ . '-' . int(rand(1_000_000));

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::SignalQueryGreeter)],
    activities => [],
);

# Drive the worker poll loops concurrently with the test body; await_result
# surfaces a worker crash promptly rather than hanging the per-result wait.
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

sub await_with_worker ($future, $timeout = 120) {
    return $tw->await_result($future, $timeout);
}

# IDEMPOTENT reads only (query, fetch result): $producer returns a FRESH future
# per attempt so a transient load-stall transport failure (DEADLINE_EXCEEDED,
# UNAVAILABLE, or an h2/http2 protocol hiccup) — fired when this loaded box
# starves the worker mid-poll — is re-issued rather than failing the subtest. A
# real (non-transient) error still surfaces immediately. Never wrap
# start_workflow / signal / terminate (non-idempotent) in this.
sub await_idempotent ($producer) {
    return $tw->await_idempotent($producer);
}

T2->subtest('signal drives a Perl :Signal handler; query reads :Query state (T-cli-signal-1, T-cli-query-1)' => sub {
    # start_workflow / signal are NON-idempotent: on a CPU-saturated box a clean
    # DEADLINE_EXCEEDED can be raised whose RPC may have reached the server, so
    # route them through await_with_retry (P10.0.6 run7/run9). A start retry that
    # hits WorkflowAlreadyStarted means the first attempt landed — re-fetch the
    # handle. A signal retry on a clean timeout is safe here: the workflow merely
    # sets the name idempotently and the test asserts the post-signal state.
    my $greet_id = unique_id('greet');
    my $handle = $tw->await_with_retry(
        sub {
            $client->start_workflow(
                'SignalQueryGreeter', [],
                id => $greet_id, task_queue => $task_queue);
        },
        on_already_started => sub { $client->get_workflow_handle($greet_id) },
    );

    # Before the signal: the query observes the empty initial name.
    my $before = await_idempotent(sub { $handle->query('currentName') });
    T2->is($before, '', 'query observes empty name before the signal');

    # Send the signal; the worker's :Signal handler sets the name and the
    # wait_condition resumes the parked :Run.
    $tw->await_with_retry(sub { $handle->signal('setName', ['Ada']) });

    # The query now observes the signalled name (T-cli-query-1), proving the
    # signal was processed by the Perl worker (T-cli-signal-1). Poll briefly: a
    # signal is async, so the worker may not have applied it before the next
    # query is dispatched.
    my $after;
    for (1 .. 20) {
        $after = await_idempotent(sub { $handle->query('currentName') });
        last if $after eq 'Ada';
        await_future($loop->delay_future(after => 0.25));
    }
    T2->is($after, 'Ada', 'query observes the signalled name after the signal');

    # The signal unblocked wait_condition; the workflow greets and completes.
    my $result = await_idempotent(sub { $handle->result });
    T2->is($result, 'Hello, Ada!', 'signal unblocked the workflow to completion');
});

T2->subtest('query against a terminated workflow with reject_condition raises QueryRejected (T-cli-query-2)' => sub {
    my $reject_id = unique_id('reject');
    my $handle = $tw->await_with_retry(
        sub {
            $client->start_workflow(
                'SignalQueryGreeter', [],
                id => $reject_id, task_queue => $task_queue);
        },
        on_already_started => sub { $client->get_workflow_handle($reject_id) },
    );

    # Terminate the run (never signalled, so it is parked on wait_condition),
    # then query with reject_condition NOT_OPEN — the server rejects because the
    # workflow is no longer open. Terminate is idempotent enough to retry on a
    # clean timeout (re-terminating an already-terminated run is a no-op).
    $tw->await_with_retry(
        sub { $handle->terminate(reason => 'terminated for reject test') });

    my $err = exception_from(sub {
        await_idempotent(sub {
            $handle->query('currentName', [],
                reject_condition => QUERY_REJECT_NOT_OPEN);
        });
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::QueryRejected'),
        'reject_condition query on a terminated workflow raises QueryRejected',
    ) or T2->diag('got: ' . ($err // 'no exception'));
});

# Clean shutdown: initiate worker shutdown (poll loops drain on the ShutDown
# sentinel), await the run future so finalize + free + fork-pool teardown all
# complete, then close the client and stop the server. No orphaned processes.
$tw->shutdown(120);
T2->ok($worker->is_shutdown, 'worker shut down cleanly after run drained');

$client->connection->close if defined $client;
teardown();

T2->done_testing;
