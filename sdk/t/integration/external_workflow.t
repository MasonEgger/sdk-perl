# ABOUTME: Integration test for external workflow handles (spec section 20,
# ABOUTME: P6.3, T-ext-10): a driver workflow signals then cancels a target by id
# ABOUTME: through an ExternalWorkflowHandle; the target observes the signal and
# ABOUTME: reaches a cancelled state. Signalling a non-existent id surfaces as
# ABOUTME: Temporalio::Exception::Application. Skips without a dev server.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use Scalar::Util ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): skip_all when the dev server CLI is unavailable.
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

require WfDef::ExtTarget;
require WfDef::ExtDriver;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub unique_id ($prefix) {
    return "perl-sdk-ext-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = do {
    my $f = Temporalio::Client->connect(
        $server->target, namespace => 'default', runtime => $runtime);
    $loop->await($f);
    $f->get;
};

my $task_queue = 'perl-sdk-ext-' . $$ . '-' . int(rand(1_000_000));

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::ExtTarget WfDef::ExtDriver)],
);

my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

sub await_with_worker ($future, $timeout = 120) {
    return $tw->await_result($future, $timeout);
}

T2->subtest('driver signals then cancels a target by id (T-ext-10a)' => sub {
    my $target_id = unique_id('target');

    # Start the target first so the driver's external handle resolves to a live
    # workflow.
    my $target = await_with_worker($client->start_workflow(
        'ExtTarget',
        [],
        id         => $target_id,
        task_queue => $task_queue,
    ));

    # The driver signals then cancels the target by id.
    my $driver = await_with_worker($client->start_workflow(
        'ExtDriver',
        ['signal_cancel', $target_id],
        id         => unique_id('driver'),
        task_queue => $task_queue,
    ));
    my $driver_result = await_with_worker($driver->result, 60);
    T2->is($driver_result, 'done',
        'driver signalled and cancelled the target through the external handle');

    # The target observed the signal.
    my $signalled = await_with_worker(
        $target->query('was_signalled'), 60);
    T2->is($signalled, 1, 'target observed the external signal');

    # The target reaches a cancelled terminal state — its result raises a
    # cancellation-flavoured failure.
    my $err = exception_from(sub { await_with_worker($target->result, 60) });
    T2->ok(Scalar::Util::blessed($err),
        'awaiting the cancelled target result raises a failure')
        or T2->diag('got: ' . ($err // 'no exception'));
});

T2->subtest('signalling a non-existent id surfaces as Application (T-ext-10b)' => sub {
    my $driver = await_with_worker($client->start_workflow(
        'ExtDriver',
        ['missing', unique_id('ghost')],
        id         => unique_id('driver-missing'),
        task_queue => $task_queue,
    ));
    my $err = exception_from(sub { await_with_worker($driver->result, 60) });
    T2->ok(Scalar::Util::blessed($err),
        'signalling a non-existent workflow fails the driver')
        or T2->diag('got: ' . ($err // 'no exception'));

    # The failure chain contains an Application error (the converted not-found
    # signal failure — spec section 20.3).
    my $app;
    my $cur = $err;
    while (Scalar::Util::blessed($cur)) {
        if ($cur->isa('Temporalio::Exception::Application')) {
            $app = $cur;
            last;
        }
        $cur = $cur->can('cause') ? $cur->cause : undef;
    }
    T2->ok($app,
        'the failure chain contains a Temporalio::Exception::Application')
        or T2->diag('chain: ' . ($err // 'undef'));
});

$tw->shutdown(120);
T2->ok($worker->is_shutdown, 'worker shut down cleanly after run drained');

$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
