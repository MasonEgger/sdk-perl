# ABOUTME: RED/GREEN for step I7 direction A (closes GitHub #7 half A): a
# ABOUTME: cancel delivered to a RUNNING pooled (fork) sync activity must carry
# ABOUTME: its reason + ActivityCancellationDetails across the fork boundary,
# ABOUTME: and a worker_shutdown-caused cancel must also flip the pooled
# ABOUTME: child's is_worker_shutdown. Python parity: worker/_activity.py
# ABOUTME: :221-226 sets activity.cancellation_details (+ is_worker_shutdown)
# ABOUTME: alongside the cancel; the shared-state manager's worker_shutdown_event
# ABOUTME: (worker/_activity.py:549-584,692,701) is set at shutdown-begin,
# ABOUTME: before the shutdown-driven cancel. Today (pre-fix) the fork-pool
# ABOUTME: cancel frame carries only { op => 'cancel', token }, so the child's
# ABOUTME: ctx->cancellation_details stays undef and is_worker_shutdown stays
# ABOUTME: false even when the cause WAS worker shutdown (Pool.pm ~:303/:388,
# ABOUTME: Context.pm ~:79-82/:91-95 deviation notes).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Temp ();
use FindBin ();
use Time::HiRes ();

use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;
use IO::Async::Loop ();

use Temporalio::Activity ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Activity::Pool ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();

require ActDef::PoolCancelDetails;

my $loop = IO::Async::Loop->new;

sub await_f ($f) { return $f->get }

sub run_to_ready ($f, $timeout = 40) {
    $loop->await(Future->wait_any($f->without_cancel,
        $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    return $f;
}

sub wait_for ($predicate, $timeout = 15) {
    my $deadline = Time::HiRes::time() + $timeout;
    while (!$predicate->()) {
        die "condition not reached within ${timeout}s\n"
            if Time::HiRes::time() > $deadline;
        $loop->await($loop->delay_future(after => 0.05));
    }
    return;
}

my $dir = File::Temp::tempdir(CLEANUP => 1);

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
my $Cancel = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.Cancel');
my $Details = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityCancellationDetails');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.ActivityTaskCompletion');

sub cancel_task_bytes ($token, $reason, %flags) {
    return $ActivityTask->new({
        task_token => $token,
        cancel     => $Cancel->new({
            reason  => $reason,
            details => $Details->new({ %flags }),
        }),
    })->encode;
}

# Drive ActDef::PoolCancelDetails (a real forked child) through the REAL
# ActivityDispatcher + Pool, deliver a Cancel task once the child is
# demonstrably running (the started_file marker, pool-live-cancel.t's
# pattern), and return the decoded activity result hashref. A true
# __notify_shutdown flag (stripped before building the Cancel proto) calls
# $dispatcher->notify_shutdown BEFORE the cancel is delivered: the real
# spec R84 shutdown sequencing (shutdown-begin, THEN the shutdown-driven
# cancel propagates): a worker_shutdown-reasoned Cancel job alone does not
# flip is_worker_shutdown, matching the async path (ActivityDispatcher's
# $worker_shutdown_event is driven only by notify_shutdown, never inferred
# from a Cancel job's reason).
sub run_pooled_cancel ($token, $reason, %flags) {
    my $notify_shutdown = delete $flags{__notify_shutdown};
    my $dc          = Temporalio::Converter::Data->new;
    my $registry    = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::PoolCancelDetails']);
    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => Temporalio::Activity::Pool->new(
            loop        => $loop,
            max_workers => 1,
            registry    => Temporalio::Worker::ActivityRegistry->new(
                activities => ['ActDef::PoolCancelDetails']),
        ),
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
    );

    my $started_file = "$dir/started-$token";
    my ($started_p)  = $dc->payload_converter->to_payload($started_file);
    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-1',
        activity_type      => 'PoolCancelDetails',
        input              => [$started_p],
        attempt            => 1,
    });
    my $dispatch_f = $dispatcher->dispatch_task(
        $ActivityTask->new({ task_token => $token, start => $start })->encode);

    wait_for(sub { -e $started_file });

    $dispatcher->notify_shutdown if $notify_shutdown;
    run_to_ready($dispatcher->dispatch_task(
        cancel_task_bytes($token, $reason, %flags)), 10);
    run_to_ready($dispatch_f);

    T2->is(scalar(@completions), 1, 'one completion sent');
    my $comp = $Completion->decode($completions[0]);
    T2->is($comp->result->which_status, 'completed',
        'the body observed the cancel cooperatively and returned normally'
            . ' (it reports the details rather than throwing)');
    my ($result) = await_f($dc->from_payloads([$comp->result->completed->result]));
    return $result;
}

T2->subtest('PAUSED cancel: pooled child observes reason + paused flag' => sub {
    my $result = run_pooled_cancel('tok-pool-paused', 4, is_paused => 1);

    T2->is($result->{reason}, 'PAUSED',
        'pooled child reports the cancel reason'
            . ' (pre-fix: cancellation_details is undef in the child)');
    T2->ok($result->{paused}, 'paused flag crossed the fork');
    T2->ok(!$result->{worker_shutdown}, 'worker_shutdown unset');
    T2->ok(!$result->{is_worker_shutdown},
        'is_worker_shutdown stays false for a plain paused cancel');
});

T2->subtest(
    'WORKER_SHUTDOWN cancel: pooled child observes reason + is_worker_shutdown'
        => sub
{
    my $result = run_pooled_cancel('tok-pool-shutdown', 3,
        is_worker_shutdown => 1, __notify_shutdown => 1);

    T2->is($result->{reason}, 'WORKER_SHUTDOWN',
        'pooled child reports the WORKER_SHUTDOWN reason');
    T2->ok($result->{worker_shutdown}, 'worker_shutdown flag crossed the fork');
    T2->ok($result->{is_worker_shutdown},
        'the pooled child\'s is_worker_shutdown flips true'
            . ' (pre-fix: the worker-shutdown event does not cross the fork)');
});

# ---------------------------------------------------------------------------
# Parity: a pooled activity's cancellation_details for a given reason match
# what the async (main-loop) path reports for the SAME reason, reusing
# t/unit/activity_cancellation_details.t's own async-path expectations.
# ---------------------------------------------------------------------------
T2->subtest('parity: pooled cancellation_details match the async path' => sub {
    my $token = 'tok-async-shutdown';
    my $dc    = Temporalio::Converter::Data->new;
    my %seen;
    my $fn = Temporalio::Activity::FunctionDefinition->new(
        name => 'waiter',
        code => async sub (@) {
            my $ctx = Temporalio::Activity::context();
            await $ctx->cancellation->cancelled;
            my $d = $ctx->cancellation_details;
            $seen{reason}          = $d->reason;
            $seen{worker_shutdown} = $d->worker_shutdown ? 1 : 0;
            return { %seen };
        },
    );
    my $registry   = Temporalio::Worker::ActivityRegistry->new(
        activities => [$fn]);
    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
    );
    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-1',
        activity_type      => 'waiter',
        input              => [],
        attempt            => 1,
    });
    my $run_f = $dispatcher->dispatch_task(
        $ActivityTask->new({ task_token => $token, start => $start })->encode);
    $dispatcher->dispatch_task(
        cancel_task_bytes($token, 3, is_worker_shutdown => 1))->get;
    $run_f->get;

    my $comp = $Completion->decode($completions[0]);
    my ($async_result) =
        await_f($dc->from_payloads([$comp->result->completed->result]));

    my $pooled_result = run_pooled_cancel('tok-pool-parity', 3,
        is_worker_shutdown => 1);

    T2->is($pooled_result->{reason}, $async_result->{reason},
        'pooled and async paths report the SAME reason for the same cancel');
    T2->is($pooled_result->{worker_shutdown}, $async_result->{worker_shutdown},
        'pooled and async paths agree on the worker_shutdown flag');
});

T2->done_testing;
