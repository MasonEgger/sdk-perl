# ABOUTME: Integration tests for start_workflow (spec section 7.4): T-cli-start-1
# ABOUTME: (start returns a handle with workflow_id + run_id) and T-cli-start-2
# ABOUTME: (a second start of a running id raises WorkflowAlreadyStarted).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use Scalar::Util ();

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor the TEMPORAL_CLI
# env override first, then scan PATH. No download is ever attempted here —
# offline CI must stay green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Loaded after the gate so machines without the CLI never compile the
# FFI-heavy stack.
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Core::Proto;

Temporalio::Core::Proto->load;

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

my $client = await_future(Temporalio::Client->connect(
    $server->target,
    namespace => 'default',
    runtime   => $runtime,
));

# A unique id per run so reruns against a persistent server don't collide.
my $wf_id = 'perl-sdk-start-' . $$ . '-' . int(rand(1_000_000));

T2->subtest('start_workflow returns a handle with workflow_id + run_id (T-cli-start-1)' => sub {
    my $handle = await_future($client->start_workflow(
        'NoSuchWorkflowType',           # no worker — the run just stays open
        [ 'Alice' ],
        id         => $wf_id,
        task_queue => 'perl-sdk-demo',
    ));
    T2->isa_ok($handle, 'Temporalio::Client::WorkflowHandle');
    T2->is($handle->workflow_id, $wf_id, 'handle carries the workflow id');
    T2->like($handle->run_id, qr/\S/, 'handle carries a run id');
    T2->is($handle->first_execution_run_id, $handle->run_id,
        'first_execution_run_id is the first run id');
});

T2->subtest('a second start of a running id raises WorkflowAlreadyStarted (T-cli-start-2)' => sub {
    my $err = exception_from(sub {
        await_future($client->start_workflow(
            'NoSuchWorkflowType',
            [ 'Bob' ],
            id              => $wf_id,            # same id, still running
            task_queue      => 'perl-sdk-demo',
            id_reuse_policy => 'reject_duplicate',
        ));
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowAlreadyStarted'),
        'second start raises WorkflowAlreadyStarted',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    T2->is($err->workflow_id, $wf_id, 'exception carries the workflow id')
        if Scalar::Util::blessed($err)
        && $err->can('workflow_id');
});

# A unique workflow id, distinct from $wf_id, for each of the P1.11 cases.
sub unique_id ($prefix) {
    return "perl-sdk-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

# Drain an async iterator to a list (each ->next resolves a Future).
sub drain ($iter, $max = 1000) {
    my @out;
    while (@out < $max) {
        my $item = await_future($iter->next);
        last unless defined $item;
        push @out, $item;
    }
    return @out;
}

T2->subtest('result on a run-timeout=1 workflow with no worker raises WorkflowFailure cause Timeout (T-cli-result-3)' => sub {
    my $handle = await_future($client->start_workflow(
        'NoSuchWorkflowType',
        [],
        id          => unique_id('timeout'),
        task_queue  => 'perl-sdk-demo',
        run_timeout => 1,                  # 1s; no worker ever picks it up
    ));
    my $err = exception_from(sub { await_future($handle->result, 30) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        'timed-out workflow -> WorkflowFailure',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    T2->ok(
        Scalar::Util::blessed($err) && Scalar::Util::blessed($err->cause)
            && $err->cause->isa('Temporalio::Exception::Timeout'),
        'cause is a Timeout',
    ) if Scalar::Util::blessed($err) && $err->can('cause');
});

T2->subtest('terminate then result raises WorkflowFailure cause Terminated with reason (T-cli-terminate-1)' => sub {
    my $handle = await_future($client->start_workflow(
        'NoSuchWorkflowType', [],
        id => unique_id('terminate'), task_queue => 'perl-sdk-demo',
    ));
    await_future($handle->terminate(reason => 'stop please'));
    my $err = exception_from(sub { await_future($handle->result, 30) });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure'),
        'terminated workflow -> WorkflowFailure',
    ) or T2->diag('got: ' . ($err // 'no exception'));
    if (Scalar::Util::blessed($err) && $err->can('cause')) {
        my $cause = $err->cause;
        T2->ok(
            Scalar::Util::blessed($cause)
                && $cause->isa('Temporalio::Exception::Terminated'),
            'cause is Terminated',
        );
        T2->is($cause->reason, 'stop please', 'terminate reason preserved')
            if Scalar::Util::blessed($cause) && $cause->can('reason');
    }
});

T2->subtest('describe returns populated workflow_execution_info (T-cli-describe-1)' => sub {
    my $id = unique_id('describe');
    my $handle = await_future($client->start_workflow(
        'NoSuchWorkflowType', [],
        id => $id, task_queue => 'perl-sdk-demo',
    ));
    my $desc = await_future($handle->describe);
    my $info = $desc->workflow_execution_info;
    T2->ok(defined $info, 'describe carries workflow_execution_info');
    T2->is($info->execution->workflow_id, $id, 'info has the workflow id')
        if defined $info;
    T2->is($info->status, 1, 'status is RUNNING (no worker)')
        if defined $info;          # WORKFLOW_EXECUTION_STATUS_RUNNING == 1
});

T2->subtest('cancel records a cancel-requested event in history (T-cli-cancel-1)' => sub {
    my $id = unique_id('cancel');
    my $handle = await_future($client->start_workflow(
        'NoSuchWorkflowType', [],
        id => $id, task_queue => 'perl-sdk-demo',
    ));
    await_future($handle->cancel(reason => 'never mind'));
    # No worker processes the cancel, but the server records a
    # WorkflowExecutionCancelRequested event — observable via fetch_history.
    my @events = drain($handle->fetch_history_events);
    my $found = grep {
        ($_->which_attributes // '')
            eq 'workflow_execution_cancel_requested_event_attributes'
    } @events;
    T2->ok($found, 'history contains a cancel-requested event');
});

T2->subtest('list_workflows iterates 3 started workflows (T-cli-list-1)' => sub {
    my $wf_type = 'PerlSdkListType' . $$;
    my %ids;
    for (1 .. 3) {
        my $id = unique_id('list');
        $ids{$id} = 1;
        await_future($client->start_workflow(
            $wf_type, [],
            id => $id, task_queue => 'perl-sdk-demo',
        ));
    }
    # Visibility is eventually consistent — poll the list query a few times.
    my @seen;
    for my $attempt (1 .. 10) {
        my $iter = $client->list_workflows(qq{WorkflowType = "$wf_type"});
        @seen = grep { $ids{$_} }
            map { $_->execution->workflow_id } drain($iter);
        last if @seen >= 3;
        $loop->await($loop->timeout_future(after => 1));
    }
    T2->is(scalar(@seen), 3, 'list_workflows iterated all 3 started workflows')
        or T2->diag('saw: ' . join(', ', @seen));
});

$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
