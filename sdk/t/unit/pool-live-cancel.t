# ABOUTME: Spec R19 (finding L15): a cancel arriving WHILE a pooled sync
# ABOUTME: activity runs must reach the forked child. Pre-fix, cancellation
# ABOUTME: crossed the fork boundary exactly once, as a boolean captured at
# ABOUTME: dispatch time (ActivityDispatcher.pm `cancelled =>
# ABOUTME: $cancellation->is_cancelled` and the pool child's
# ABOUTME: `ChildCancellation->new(cancelled => $inv->is_cancelled)`), so a
# ABOUTME: later cancel was invisible in-child: the body spun on is_cancelled
# ABOUTME: until its own deadline and the activity completed instead of
# ABOUTME: reporting cancelled.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Temp ();
use FindBin ();
use Scalar::Util ();
use Time::HiRes ();

use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();

use Temporalio::Activity ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Activity::Invocation ();
use Temporalio::Activity::Pool ();
use Temporalio::Cancellation ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();

my $loop = IO::Async::Loop->new;

sub run_to_ready ($f, $timeout = 40) {
    $loop->await(Future->wait_any($f->without_cancel,
        $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    return $f;
}

# Block (without resolving any future) until $predicate is true, re-checking
# every 50ms. Used to wait for the child's "started" marker file.
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

# The body announces it is running by touching $started_file, then polls
# is_cancelled. When the cancel is observed it throws Cancelled, noting
# whether the cancellation FUTURE resolved too (both surfaces must flip,
# per the R19 acceptance: "cancellation future / is_cancelled"). If no
# cancel arrives before the deadline it returns a marker instead — the
# pre-fix behavior (finding L15), and a bound that keeps the suite from
# hanging.
sub spinner_registry () {
    return Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'spin_until_cancelled',
                sync => 1,
                code => sub ($started_file) {
                    my $ctx    = Temporalio::Activity::context();
                    my $cancel = $ctx->cancellation;
                    my $future = $cancel->cancelled;    # instantiate up front
                    open my $fh, '>', $started_file
                        or die "cannot create $started_file: $!";
                    close $fh;
                    my $deadline = Time::HiRes::time() + 15;
                    while (Time::HiRes::time() <= $deadline) {
                        if ($cancel->is_cancelled) {
                            my $state = $future->is_ready
                                ? 'future-ready' : 'future-pending';
                            Temporalio::Exception::Cancelled->throw(
                                message =>
                                    "pool child observed cancel ($state)");
                        }
                        Time::HiRes::sleep(0.05);
                    }
                    return 'timed-out-waiting-for-cancel';
                },
            ),
        ],
    );
}

sub invocation_for ($token, $started_file) {
    return Temporalio::Activity::Invocation->new(
        activity_type => 'spin_until_cancelled',
        args          => [$started_file],
        info          => { task_token => $token },
        task_token    => $token,
    );
}

# ---------------------------------------------------------------------------
# End to end through the REAL dispatcher (the finding-L15 repro): start a
# pooled sync activity, deliver a Cancel activity task once the child is
# running, and require a CANCELLED completion. Pre-fix, _handle_cancel
# cancels the parent-side token but the child captured only the dispatch-time
# boolean, so the body spins to its deadline and the completion comes back
# COMPLETED.
# ---------------------------------------------------------------------------
T2->subtest('dispatcher cancel task reaches the running pooled child' => sub {
    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => spinner_registry(),
        data_converter => Temporalio::Converter::Data->new,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => Temporalio::Activity::Pool->new(
            loop        => $loop,
            max_workers => 1,
            registry    => spinner_registry(),
        ),
        completer => sub ($bytes) { push @completions, $bytes; Future->done },
    );

    my $ActivityTask = Temporalio::Core::Proto::resolve(
        'coresdk.activity_task.ActivityTask');
    my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
    my $Cancel = Temporalio::Core::Proto::resolve(
        'coresdk.activity_task.Cancel');
    my $Completion = Temporalio::Core::Proto::resolve(
        'coresdk.ActivityTaskCompletion');

    my $token        = 'tok-disp-cancel';
    my $started_file = "$dir/started-dispatcher";
    my $dc           = Temporalio::Converter::Data->new;
    my ($input)      = $dc->payload_converter->to_payload($started_file);
    my $start        = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-1',
        activity_type      => 'spin_until_cancelled',
        input              => [$input],
        attempt            => 1,
    });
    my $dispatch_f = $dispatcher->dispatch_task(
        $ActivityTask->new({ task_token => $token, start => $start })->encode);

    wait_for(sub { -e $started_file });

    # The child is demonstrably running: deliver the cancel task.
    run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
        task_token => $token,
        cancel     => $Cancel->new({}),
    })->encode), 10);

    run_to_ready($dispatch_f);
    T2->is(scalar(@completions), 1, 'one completion sent');
    my $comp = $Completion->decode($completions[0]);
    T2->is($comp->result->which_status, 'cancelled',
        'completion reports CANCELLED, not a normal completion'
            . ' (pre-fix: the child never saw the cancel, finding L15)');
});

# ---------------------------------------------------------------------------
# Pool level: invoke() accepts the parent-side cancellation token and delivers
# a post-dispatch cancel to the running child, where BOTH in-child surfaces
# (is_cancelled and the cancellation future) observe it and the activity
# resolves cancelled.
# ---------------------------------------------------------------------------
T2->subtest('pool delivers a live cancel; child future + flag observe it' => sub {
    my $pool = Temporalio::Activity::Pool->new(
        loop        => $loop,
        max_workers => 1,
        registry    => spinner_registry(),
    );

    my $started_file = "$dir/started-pool";
    my $cancellation = Temporalio::Cancellation->new;
    my $f            = $pool->invoke(
        invocation_for('tok-pool-cancel', $started_file),
        cancellation => $cancellation,
    );

    wait_for(sub { -e $started_file });
    $cancellation->cancel;

    run_to_ready($f);
    T2->ok($f->is_failed, 'invoke fails once the child observes the cancel');
    my ($error) = $f->failure;
    T2->ok(Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Cancelled'),
        'error is the child-thrown Cancelled (identity via the R5 channel)')
        or T2->diag('got: ' . ($error // 'undef'));
    if (Scalar::Util::blessed($error)) {
        T2->like($error->message, qr/pool child observed cancel/,
            'child observed the cancel through its Context');
        T2->like($error->message, qr/future-ready/,
            'the in-child cancellation FUTURE resolved as well');
    }

    $pool->close;
});

T2->done_testing;
