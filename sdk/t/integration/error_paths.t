# ABOUTME: Phase 5 failure-path gate (spec section 7.6, P5.2): WorkflowHandle->result
# ABOUTME: error mapping end-to-end against a live dev server, driven by REAL
# ABOUTME: server-produced terminal events / Failure protos.
# ABOUTME:  - T-cli-result-2: a workflow that throws Application(type 'X') -> result
# ABOUTME:    raises WorkflowFailure whose cause is an Application carrying that type
# ABOUTME:    (the cause is rebuilt by the P1.5 Failure converter from the real
# ABOUTME:    WorkflowExecutionFailed failure proto).
# ABOUTME:  - T-cli-result-4: continue-as-new both ways. follow_runs => 1 (default)
# ABOUTME:    follows the chain to the final run's value; follow_runs => 0 raises
# ABOUTME:    WorkflowContinuedAsNew carrying the new run id.
# ABOUTME:  - T-cli-result-5: a transient UNAVAILABLE during the result long-poll is
# ABOUTME:    retried transparently (core retries it because every poll sets retry=1)
# ABOUTME:    and the final resolve still succeeds.
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
# then scan PATH (~/.local/bin is on PATH). No download is ever attempted.
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
require Temporalio::Exception::Application;
require Temporalio::Exception::WorkflowContinuedAsNew;
require Temporalio::Exception::WorkflowFailure;

# Fixtures: AppFailer throws an Application(type 'BoomError') directly from :Run;
# CanCounter continues-as-new to itself until a counter reaches its target.
require WfDef::AppFailer;
require WfDef::CanCounter;

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
    return "perl-sdk-error-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-error-' . $$ . '-' . int(rand(1_000_000));

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::AppFailer WfDef::CanCounter)],
);

# Drive the worker poll loops concurrently with the test body; await_result
# surfaces a worker crash promptly rather than hanging the per-result wait.
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

sub await_with_worker ($future, $timeout = 120) {
    return $tw->await_result($future, $timeout);
}

# T-cli-result-2: a workflow that throws an Application failure with a stable
# type ends WorkflowExecutionFailed. result() decodes the REAL server Failure
# proto via the P1.5 converter and raises WorkflowFailure whose cause is an
# Application carrying that type. Verified against sdk-python client/_workflow.py
# (WorkflowExecutionFailed -> WorkflowFailureError, cause from failure proto).
T2->subtest('failed workflow -> WorkflowFailure wrapping Application(type) (T-cli-result-2)' => sub {
    my $handle = $tw->start_workflow_with_retry($client,
        'AppFailer',
        [],
        id         => unique_id('appfail'),
        task_queue => $task_queue,
    );

    my $result;
    my $err = exception_from(sub { $result = await_with_worker($handle->result, 60) });

    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        'failed workflow -> WorkflowFailure',
    ) or T2->diag('got: ' . ($err // ('no exception, result=' . ($result // 'undef'))));

    my $cause =
        (Scalar::Util::blessed($err) && $err->can('cause')) ? $err->cause : undef;
    T2->ok(
        Scalar::Util::blessed($cause)
            && $cause->isa('Temporalio::Exception::Application'),
        'WorkflowFailure cause is an Application failure',
    ) or T2->diag('cause: ' . ($cause // 'undef'));

    T2->is($cause->type, 'BoomError',
        'Application cause carries the type from the real failure proto')
        if Scalar::Util::blessed($cause) && $cause->can('type');
});

# T-cli-result-4: continue-as-new, both directions. The CanCounter chain runs
# start -> CAN -> CAN -> complete(target) under one worker.
T2->subtest('continue-as-new follow_runs both ways (T-cli-result-4)' => sub {
    # follow_runs => 1 (default): result follows the run chain to the final
    # WorkflowExecutionCompleted and returns its value.
    my $followed = $tw->start_workflow_with_retry($client,
        'CanCounter',
        [ 0, 2 ],
        id         => unique_id('can-follow'),
        task_queue => $task_queue,
    );
    my $value = await_with_worker($followed->result, 60);
    T2->is($value, 2,
        'follow_runs => 1 follows the CAN chain to the final run value');

    # follow_runs => 0: the first run is a ContinuedAsNew, so result raises
    # WorkflowContinuedAsNew carrying the new run id rather than following.
    my $stopped = $tw->start_workflow_with_retry($client,
        'CanCounter',
        [ 0, 2 ],
        id         => unique_id('can-stop'),
        task_queue => $task_queue,
    );
    my $err = exception_from(
        sub { await_with_worker($stopped->result(follow_runs => 0), 60) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowContinuedAsNew'),
        'follow_runs => 0 raises WorkflowContinuedAsNew',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->can('new_run_id')
            && defined $err->new_run_id
            && length $err->new_run_id,
        'WorkflowContinuedAsNew carries the new run id',
    ) or T2->diag('new_run_id: '
        . ((Scalar::Util::blessed($err) && $err->can('new_run_id'))
            ? ($err->new_run_id // 'undef') : 'n/a'));
});

# T-cli-result-5: a transient UNAVAILABLE during the result long-poll is retried
# transparently and the final resolve still succeeds. Retry is the responsibility
# of sdk-core, NOT of Perl: the SDK never wraps result()'s poll in a Perl-level
# retry loop — it sets retry => 1 on the poll RPC and core absorbs transient
# UNAVAILABLE/RESOURCE_EXHAUSTED/DEADLINE_EXCEEDED against the client RetryConfig
# (spec section 7.6 point 3 + section 7.5). So we verify the contract that makes
# the retry transparent: every result long-poll GetWorkflowExecutionHistory must
# carry retry => 1. We spy on _rpc_call to capture the retry flag, then delegate
# to the real RPC — the call core would have retried past any transient
# UNAVAILABLE — and assert the result still resolves to the real value.
T2->subtest('transient UNAVAILABLE during result long-poll is retried (T-cli-result-5)' => sub {
    my $handle = $tw->start_workflow_with_retry($client,
        'CanCounter',
        [ 2, 2 ],    # target already reached -> completes on the first run
        id         => unique_id('retry'),
        task_queue => $task_queue,
    );

    my $poll_seen      = 0;
    my $poll_retry_off = 0;
    my $orig_rpc_call  = \&Temporalio::Client::_rpc_call;

    no warnings 'redefine';
    local *Temporalio::Client::_rpc_call = sub {
        my ($self, $rpc, $request, %opts) = @_;
        if ($rpc eq 'GetWorkflowExecutionHistory') {
            $poll_seen++;
            # Default is retry => 1; the long-poll must not disable it, else
            # core would surface transient UNAVAILABLE instead of retrying it.
            my $retry = exists $opts{retry} ? $opts{retry} : 1;
            $poll_retry_off++ unless $retry;
        }
        return $self->$orig_rpc_call($rpc, $request, %opts);
    };

    my $resolved;
    my $err = exception_from(sub { $resolved = await_with_worker($handle->result, 60) });

    T2->ok($poll_seen, 'result long-poll issued GetWorkflowExecutionHistory')
        or T2->diag("poll_seen=$poll_seen");
    T2->is($poll_retry_off, 0,
        'every result long-poll carries retry => 1 so core retries transient UNAVAILABLE');
    T2->ok(!defined $err, 'result resolves (core absorbs any transient failure)')
        or T2->diag('got error: ' . ($err // 'undef'));
    T2->is($resolved, 2, 'the final resolve returns the real completed value');
});

# Clean shutdown: drain the worker poll loops, await the run future so finalize +
# free + teardown all complete, then close the client and stop the server. No
# orphaned processes.
$tw->shutdown(120);
T2->ok($worker->is_shutdown, 'worker shut down cleanly after run drained');

$client->connection->close if defined $client;
teardown();

T2->done_testing;
