# ABOUTME: Integration test for child workflows (spec section 18, P6.1, T-child-13):
# ABOUTME: a parent execute_child_workflow returns the child value, a started
# ABOUTME: child is signalled via the handle, and a failing child surfaces as
# ABOUTME: Temporalio::Exception::ChildWorkflow. Skips without a dev server.
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

require WfDef::E2EParent;
require WfDef::E2EChild;

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
    return "perl-sdk-child-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = await_future(Temporalio::Client->connect(
    $server->target,
    namespace => 'default',
    runtime   => $runtime,
));

my $task_queue = 'perl-sdk-child-' . $$ . '-' . int(rand(1_000_000));

# Both the parent and child workflow types run on the one worker/task queue so
# the child is started on the same queue (the default parent task queue).
my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::E2EParent WfDef::E2EChild)],
);

my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

sub await_with_worker ($future, $timeout = 120) {
    return $tw->await_result($future, $timeout);
}

T2->subtest('parent execute_child_workflow returns the child value (T-child-13a)' => sub {
    my $handle = await_with_worker($client->start_workflow(
        'E2EParent',
        ['execute', 'Alice'],
        id         => unique_id('execute'),
        task_queue => $task_queue,
    ));
    my $result = await_with_worker($handle->result, 60);
    T2->is($result, 'Hello, Alice!',
        'parent returned the child workflow result');
});

T2->subtest('parent signals a started child via the handle (T-child-13b)' => sub {
    my $handle = await_with_worker($client->start_workflow(
        'E2EParent',
        ['signal', 'ping'],
        id         => unique_id('signal'),
        task_queue => $task_queue,
    ));
    my $result = await_with_worker($handle->result, 60);
    T2->is($result, 'poked: ping',
        'the child observed the signal sent through the child handle');
});

T2->subtest('failing child surfaces as ChildWorkflow (T-child-13c)' => sub {
    my $handle = await_with_worker($client->start_workflow(
        'E2EParent',
        ['execute', 'fail'],
        id         => unique_id('fail'),
        task_queue => $task_queue,
    ));
    my $err = exception_from(sub { await_with_worker($handle->result, 60) });
    # The parent workflow fails; its failure wraps the ChildWorkflow failure,
    # whose cause is the child's Application error.
    T2->ok(Scalar::Util::blessed($err), 'a failure was raised')
        or T2->diag('got: ' . ($err // 'no exception'));

    # Walk the cause chain looking for a ChildWorkflow failure.
    my $child_failure;
    my $cur = $err;
    while (Scalar::Util::blessed($cur)) {
        if ($cur->isa('Temporalio::Exception::ChildWorkflow')) {
            $child_failure = $cur;
            last;
        }
        $cur = $cur->can('cause') ? $cur->cause : undef;
    }
    T2->ok($child_failure,
        'the failure chain contains a Temporalio::Exception::ChildWorkflow')
        or T2->diag('chain: ' . ($err // 'undef'));
});

$tw->shutdown(120);
T2->ok($worker->is_shutdown, 'worker shut down cleanly after run drained');

$client->connection->close if defined $client;
$server->shutdown;
$runtime->shutdown;

T2->done_testing;
