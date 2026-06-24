# ABOUTME: Client-side workflow update tests end-to-end against a live dev server
# ABOUTME: (spec section 19): execute_update/start_update wait-stage handling,
# ABOUTME: validator/handler rejection -> WorkflowUpdateFailed, the 'admitted'
# ABOUTME: pre-RPC Argument guard, and explicit update_id round-trip
# ABOUTME: (T-cli-update-1..7). skip_all when the dev server is unavailable.
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

require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Exception::Argument;
require Temporalio::Exception::WorkflowUpdateFailed;

require WfDef::UpdatableCounter;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

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
    return "perl-sdk-upd-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = await_future(Temporalio::Client->connect(
    $server->target,
    namespace => 'default',
    runtime   => $runtime,
));

my $task_queue = 'perl-sdk-upd-' . $$ . '-' . int(rand(1_000_000));

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::UpdatableCounter)],
    activities => [],
);

my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

sub await_with_worker ($future, $timeout = 60) {
    return $tw->await_result($future, $timeout);
}

sub start_counter ($prefix) {
    return await_with_worker($client->start_workflow(
        'UpdatableCounter',
        [],
        id         => unique_id($prefix),
        task_queue => $task_queue,
    ));
}

T2->subtest('execute_update returns the decoded result (T-cli-update-1)' => sub {
    my $handle = start_counter('exec');
    my $r = await_with_worker($handle->execute_update('add', [5]));
    T2->is($r, 5, 'execute_update returned the handler result');
});

T2->subtest('start_update accepted then ->result polls to completion (T-cli-update-2)' => sub {
    my $handle = start_counter('start');
    my $uh = await_with_worker(
        $handle->start_update('add', [3], wait_for_stage => 'accepted'));
    T2->ok($uh->isa('Temporalio::Client::WorkflowUpdateHandle'),
        'start_update returned an update handle');
    my $r = await_with_worker($uh->result);
    T2->is($r, 3, 'the update handle ->result returned the completed value');
});

T2->subtest('validator-rejected update raises WorkflowUpdateFailed (T-cli-update-3)' => sub {
    my $handle = start_counter('reject');
    my $err = exception_from(sub {
        await_with_worker($handle->execute_update('add', [-1]));
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowUpdateFailed'),
        'a validator-rejected update raises WorkflowUpdateFailed',
    ) or T2->diag('got: ' . ($err // 'no exception'));

    # The workflow is still running: a subsequent valid update succeeds.
    my $r = await_with_worker($handle->execute_update('add', [2]));
    T2->is($r, 2, 'the workflow kept running after the rejected update');
});

T2->subtest('handler ApplicationError raises WorkflowUpdateFailed (T-cli-update-4)' => sub {
    my $handle = start_counter('boom');
    my $err = exception_from(sub {
        await_with_worker($handle->execute_update('boom', []));
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowUpdateFailed'),
        'a handler ApplicationError raises WorkflowUpdateFailed',
    ) or T2->diag('got: ' . ($err // 'no exception'));
});

T2->subtest("wait_for_stage => 'admitted' raises Argument before any RPC (T-cli-update-5)" => sub {
    my $handle = $client->get_workflow_handle('does-not-matter');
    my $err = exception_from(sub {
        await_future($handle->start_update('add', [1], wait_for_stage => 'admitted'));
    });
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        "'admitted' wait stage is rejected with Argument",
    ) or T2->diag('got: ' . ($err // 'no exception'));
});

T2->subtest('update on a closed workflow is a mapped RPC error (T-cli-update-6)' => sub {
    my $handle = start_counter('closed');
    await_with_worker($handle->terminate(reason => 'closing for update test'));
    my $err = exception_from(sub {
        await_with_worker($handle->execute_update('add', [1]));
    });
    T2->ok(defined $err, 'an update on a closed workflow raises')
        or T2->diag('expected an exception');
});

T2->subtest('explicit update_id round-trips into the handle (T-cli-update-7)' => sub {
    my $handle = start_counter('id');
    my $my_id  = unique_id('updid');
    my $uh = await_with_worker(
        $handle->start_update('add', [4],
            wait_for_stage => 'accepted', update_id => $my_id));
    T2->is($uh->update_id, $my_id, 'the explicit update_id is on the handle');
    my $r = await_with_worker($uh->result);
    T2->is($r, 4, 'the explicitly-identified update completed');
});

$tw->shutdown(60);
$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
