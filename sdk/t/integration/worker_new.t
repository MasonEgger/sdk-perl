# ABOUTME: Integration tests for Temporalio::Worker construction + validate +
# ABOUTME: shutdown (spec section 8.1-8.2, T-wkr-5): worker_new/validate/shutdown
# ABOUTME: against a live dev server; no workflow/activity execution yet.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use Scalar::Util ();

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor TEMPORAL_CLI
# first, then scan PATH. No download is ever attempted here.
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
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Activity::FunctionDefinition;

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
    die "future did not resolve within ${timeout}s\n"
        unless $future->is_ready;
    return $future->get;
}

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $one_activity = sub {
    [
        Temporalio::Activity::FunctionDefinition->new(
            name => 'noop', code => sub { 'ok' }),
    ];
};

T2->subtest('worker_new + validate succeeds against a real connection' => sub {
    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => 'perl-worker-new-validate',
        activities => $one_activity->(),
    );
    T2->isa_ok($worker, 'Temporalio::Worker');

    my $err = exception_from(sub { await_future($worker->validate, 30) });
    T2->ok(!defined $err, 'validate succeeds against the dev server')
        or T2->diag('got: ' . ($err // ''));

    # initiate then finalize, then free — the spec 8.2 shutdown sequence.
    $err = exception_from(sub { await_future($worker->shutdown, 30) });
    T2->ok(!defined $err, 'shutdown completes cleanly')
        or T2->diag('got: ' . ($err // ''));
    T2->ok($worker->is_shutdown, 'worker reports shut down');
});

T2->subtest('worker against a fresh task queue constructs + shuts down cleanly (T-wkr-5)' => sub {
    # A task queue nobody is producing to: construction + validate + shutdown
    # must all succeed; no tasks are ever dispatched (no run loop yet).
    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => 'perl-worker-fresh-' . int(rand(1_000_000)),
        activities => $one_activity->(),
    );
    my $err = exception_from(sub { await_future($worker->validate, 30) });
    T2->ok(!defined $err, 'validate succeeds for a fresh task queue')
        or T2->diag('got: ' . ($err // ''));

    $err = exception_from(sub { await_future($worker->shutdown, 30) });
    T2->ok(!defined $err, 'shutdown completes cleanly');
});

T2->subtest('shutdown is idempotent' => sub {
    my $worker = Temporalio::Worker->new(
        client     => $client,
        task_queue => 'perl-worker-idempotent',
        activities => $one_activity->(),
    );
    await_future($worker->validate, 30);
    await_future($worker->shutdown, 30);
    my $err = exception_from(sub { await_future($worker->shutdown, 30) });
    T2->ok(!defined $err, 'second shutdown is a no-op');
});

$client->connection->close;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
