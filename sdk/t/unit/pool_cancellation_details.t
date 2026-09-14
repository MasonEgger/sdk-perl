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
use Temporalio::Activity::CancellationDetails ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Activity::Invocation ();
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
#
# Step F6: BOTH sides call notify_shutdown before the cancel, and both report
# is_worker_shutdown. Before F6 the async side never called it, so the only
# fields compared were reason and worker_shutdown, and the reason comparison
# would have passed on two undefs; the shutdown-observability half of spec
# R84 parity (the half this file's second subtest exists for) was not
# compared across the paths at all.
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
            $seen{reason}             = $d->reason;
            $seen{worker_shutdown}    = $d->worker_shutdown ? 1 : 0;
            $seen{is_worker_shutdown} = $ctx->is_worker_shutdown ? 1 : 0;
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
    # Shutdown-begin THEN the shutdown-driven cancel, the same spec R84
    # sequencing run_pooled_cancel's __notify_shutdown flag applies on the
    # pooled side, so is_worker_shutdown is comparable across the two paths.
    $dispatcher->notify_shutdown;
    $dispatcher->dispatch_task(
        cancel_task_bytes($token, 3, is_worker_shutdown => 1))->get;
    $run_f->get;

    my $comp = $Completion->decode($completions[0]);
    my ($async_result) =
        await_f($dc->from_payloads([$comp->result->completed->result]));

    my $pooled_result = run_pooled_cancel('tok-pool-parity', 3,
        is_worker_shutdown => 1, __notify_shutdown => 1);

    # Pin the async side's own values first: without this, the two
    # comparisons below would pass on a pair of undefs/zeros.
    T2->is($async_result->{reason}, 'WORKER_SHUTDOWN',
        'the async path reports a DEFINED reason for this cancel');
    T2->ok($async_result->{is_worker_shutdown},
        'the async path observed shutdown-begin');

    T2->is($pooled_result->{reason}, $async_result->{reason},
        'pooled and async paths report the SAME reason for the same cancel');
    T2->is($pooled_result->{worker_shutdown}, $async_result->{worker_shutdown},
        'pooled and async paths agree on the worker_shutdown flag');
    T2->is($pooled_result->{is_worker_shutdown},
        $async_result->{is_worker_shutdown},
        'pooled and async paths agree on is_worker_shutdown after'
            . ' notify_shutdown on both');
});

# ---------------------------------------------------------------------------
# Step F6 (spec "F6: Fork-pool frame pairing must be token-exact"): a cancel
# frame for a token that has already FINISHED must not land in the next
# invocation's holder on the same child.
#
# The window is real at worker shutdown, where core cancels every running
# activity: the child sends 'end' for A and replies, but the parent's reply
# pipe and its control socket are independently ordered, so a Cancel task for
# A can reach cancel_invocation while %inflight{A} and %token_conn{A} are
# still set. The frame is written to the socket A's child is no longer
# draining, and the NEXT invocation on that same child (max_workers => 1
# guarantees it is the same one) reads it during its first poll.
#
# Pre-F6, _child_drain_control keyed the cancelled flag by $msg->{token} but
# wrote $child->{holder}{details} unconditionally, so B reported A's reason
# with is_cancelled false: a cancellation_details defined while is_cancelled
# is false, a state the async path cannot produce because Python looks the
# holder up BY TOKEN (_activity.py:221, over _running_activities) and each
# running activity owns its own holder (_activity.py:741), handed to the sync
# worker's context per invocation (_activity.py:938, 968).
#
# Reproduced deterministically without touching the frame codec: A stops
# polling before it returns, so a cancel written during its tail is not
# consumed by A at all.
# ---------------------------------------------------------------------------
sub late_cancel_registry () {
    return Temporalio::Worker::ActivityRegistry->new(
        activities => [
            # A: announce, poll ONCE (so the token is current and the drain
            # path is live), announce again, then idle WITHOUT polling. The
            # cancel the parent writes during that idle window is never
            # drained by this invocation.
            Temporalio::Activity::FunctionDefinition->new(
                name => 'settle_then_idle',
                sync => 1,
                code => sub ($started_file, $settled_file) {
                    my $ctx = Temporalio::Activity::context();
                    open my $sfh, '>', $started_file
                        or die "cannot create $started_file: $!";
                    close $sfh;
                    $ctx->cancellation->is_cancelled;
                    open my $dfh, '>', $settled_file
                        or die "cannot create $settled_file: $!";
                    close $dfh;
                    Time::HiRes::sleep(1);
                    return 'a-done';
                },
            ),
            # B: poll repeatedly, giving the frame A left behind every
            # chance to be drained into THIS invocation, then report what
            # this invocation's context observed.
            Temporalio::Activity::FunctionDefinition->new(
                name => 'report_cancel_state',
                sync => 1,
                code => sub () {
                    my $ctx = Temporalio::Activity::context();
                    for (1 .. 10) {
                        $ctx->cancellation->is_cancelled;
                        Time::HiRes::sleep(0.05);
                    }
                    my $details = $ctx->cancellation_details;
                    return {
                        cancelled       => $ctx->cancellation->is_cancelled ? 1 : 0,
                        details_defined => defined $details ? 1 : 0,
                        reason          => defined $details
                            ? $details->reason : undef,
                    };
                },
            ),
        ],
    );
}

sub late_cancel_invocation ($token, $type, @args) {
    return Temporalio::Activity::Invocation->new(
        activity_type => $type,
        args          => [@args],
        info          => { task_token => $token },
        task_token    => $token,
    );
}

T2->subtest(
    'a cancel for a FINISHED token does not leak into the next invocation'
        . ' on the same child' => sub
{
    my $pool = Temporalio::Activity::Pool->new(
        loop        => $loop,
        max_workers => 1,
        registry    => late_cancel_registry(),
    );

    my $started_a = "$dir/late-started-a";
    my $settled_a = "$dir/late-settled-a";
    my $f_a       = $pool->invoke(late_cancel_invocation(
        'tok-late-a', 'settle_then_idle', $started_a, $settled_a));

    wait_for(sub { -e $settled_a });

    # A is still inflight (it is idling, not polling), so the frame is
    # written straight to the connection rather than parked.
    $pool->cancel_invocation('tok-late-a',
        Temporalio::Activity::CancellationDetails->new(
            reason => 'PAUSED', paused => 1));

    run_to_ready($f_a);
    T2->is($f_a->get, 'a-done',
        'A finished normally: it never observed the late cancel itself');

    my $f_b = $pool->invoke(
        late_cancel_invocation('tok-late-b', 'report_cancel_state'));
    run_to_ready($f_b);
    my $b = $f_b->get;

    T2->ok(!$b->{cancelled},
        'B is not cancelled: the cancelled flag is keyed by token, and the'
            . ' frame named A');
    T2->ok(!$b->{details_defined},
        'B reports NO cancellation_details for a cancel that named A'
            . ' (pre-F6: the holder write was unconditional, so B carried'
            . " A's reason with is_cancelled false)")
        or T2->diag('B saw reason: ' . ($b->{reason} // 'undef'));

    $pool->close;
});

T2->done_testing;
