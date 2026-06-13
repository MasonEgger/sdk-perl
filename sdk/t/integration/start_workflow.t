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

$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
