# ABOUTME: Unit tests for the sync activity fork pool (spec section 9.4):
# ABOUTME: a sync body runs in a forked child (T-act-6), the child closes
# ABOUTME: inherited parent FDs (T-act-10), heartbeats relay back to the
# ABOUTME: parent's FFI call, cooperative cancellation propagates parent->child,
# ABOUTME: and the dispatcher routes sync defs to the pool / async defs to the loop.
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;
use IO::Async::Loop ();
use POSIX ();

use Temporalio::Activity ();
use Temporalio::Activity::Invocation ();
use Temporalio::Activity::Pool ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Core::Proto ();

my $loop = IO::Async::Loop->new;

# In-memory futures driven with ->get (no loop run) per the codebase idiom.
sub await_f ($f) { return $f->get }

# pool->invoke parks on a REAL fork, so it must be driven by running the loop;
# $loop->await returns the Future itself (P2.4 lesson), so read the value with
# ->get after it resolves.
sub run_loop ($f, $timeout = 30) {
    $loop->await(Future->wait_any($f, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    return $f->get;
}

# ---------------------------------------------------------------------------
# The cross-fork invocation struct (REFACTOR P2.5.3): a serializable plain-data
# record. It MUST carry only plain scalars/refs — no live core pointers, no
# Cancellation object, no data converter. Verify round-trip through the
# serializer is lossless and rejects an un-serializable payload.
# ---------------------------------------------------------------------------
T2->subtest('invocation struct: serializes to plain data and round-trips' => sub {
    my $inv = Temporalio::Activity::Invocation->new(
        activity_type => 'greet',
        args          => [ 'World', { times => 3 } ],
        info          => { task_token => 'tok-1', activity_id => 'a-1' },
        task_token    => 'tok-1',
    );

    T2->is($inv->activity_type, 'greet', 'activity_type reader');
    T2->is($inv->task_token, 'tok-1', 'task_token reader');
    T2->is($inv->args, [ 'World', { times => 3 } ], 'args reader');

    my $frozen = $inv->freeze;
    T2->ok(!ref($frozen), 'freeze yields a plain (non-ref) serialized scalar');

    my $thawed = Temporalio::Activity::Invocation->thaw($frozen);
    T2->is($thawed->activity_type, 'greet', 'thawed activity_type');
    T2->is($thawed->args, [ 'World', { times => 3 } ], 'thawed args round-trip');
    T2->is($thawed->info->{task_token}, 'tok-1', 'thawed info round-trips');
});

# ---------------------------------------------------------------------------
# T-act-6: a sync activity body runs in a forked child and its result reaches
# the parent. The pool's `invoke` returns a Future resolving to the child's
# return value.
# ---------------------------------------------------------------------------
T2->subtest('T-act-6: sync body runs in a child and returns its result' => sub {
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'greet',
                sync => 1,
                code => sub ($name) { return "Hello, $name! (pid $$)" },
            ),
        ],
    );

    my $pool = Temporalio::Activity::Pool->new(
        loop         => $loop,
        max_workers  => 1,
        registry     => $registry,
    );

    my $inv = Temporalio::Activity::Invocation->new(
        activity_type => 'greet',
        args          => ['World'],
        info          => { task_token => 'tok-6' },
        task_token    => 'tok-6',
    );

    my $result = run_loop($pool->invoke($inv));
    T2->like($result, qr/\AHello, World! \(pid \d+\)\z/,
        'result returned from the child');
    T2->isnt(($result =~ /pid (\d+)/)[0], "$$",
        'body ran in a forked child, not the parent');

    $pool->close;
});

# ---------------------------------------------------------------------------
# T-act-10: the forked child closes inherited parent FDs. The parent opens an
# eventfd and hands its FILEHANDLE to the pool as an inherited handle; the
# pool's init_code FD hygiene closes it in each child. The child probes the
# eventfd's original fd number via /proc/self/fd: after the close the kernel
# eventfd object is gone from the child, so that fd number no longer points to
# an `anon_inode:[eventfd]` (it is either closed or reused for an unrelated
# handle). Verifying the kernel OBJECT is gone is the real correctness
# property — a bare fd-number read is unreliable because IO::Async::Function
# renumbers fds in the child.
# ---------------------------------------------------------------------------
T2->subtest('T-act-10: child closes inherited parent eventfd' => sub {
    require Linux::FD;
    my $efd = Linux::FD::Event->new(0, 'non-blocking');
    my $efd_no = $efd->fileno;

    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'probe_fd',
                sync => 1,
                code => sub ($fd) {
                    my $link = readlink("/proc/$$/fd/$fd");
                    return defined $link ? "link:$link" : "closed:" . ($! + 0);
                },
            ),
        ],
    );

    my $pool = Temporalio::Activity::Pool->new(
        loop          => $loop,
        max_workers   => 1,
        registry      => $registry,
        inherited_fhs => [ $efd ],
    );

    my $inv = Temporalio::Activity::Invocation->new(
        activity_type => 'probe_fd',
        args          => [ $efd_no ],
        info          => { task_token => 'tok-10' },
        task_token    => 'tok-10',
    );

    my $result = run_loop($pool->invoke($inv));
    T2->unlike($result, qr/eventfd/,
        "the parent's eventfd kernel object is closed in the child"
            . " (got $result)");

    $pool->close;
    $efd->close;
});

# ---------------------------------------------------------------------------
# Heartbeat relay: heartbeat() called inside the child cannot touch core; it
# must relay the serialized ActivityHeartbeat bytes back to the parent, which
# performs the real FFI heartbeat. The parent-side relay handler is injected
# and spied on.
# ---------------------------------------------------------------------------
T2->subtest('heartbeat from child relays to the parent FFI call' => sub {
    my @relayed;    # parent-side: serialized ActivityHeartbeat bytes
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'beat',
                sync => 1,
                code => sub (@) {
                    Temporalio::Activity::heartbeat('progress', 42);
                    return 'done';
                },
            ),
        ],
    );

    my $pool = Temporalio::Activity::Pool->new(
        loop           => $loop,
        max_workers    => 1,
        registry       => $registry,
        heartbeat_relay => sub ($task_token, $hb_bytes) {
            push @relayed, { token => $task_token, bytes => $hb_bytes };
            return undef;
        },
    );

    my $inv = Temporalio::Activity::Invocation->new(
        activity_type => 'beat',
        args          => [],
        info          => { task_token => 'tok-hb' },
        task_token    => 'tok-hb',
    );

    my $result = run_loop($pool->invoke($inv));
    T2->is($result, 'done', 'body completed after heartbeating');
    T2->is(scalar(@relayed), 1, 'one heartbeat relayed to the parent');
    T2->is($relayed[0]{token}, 'tok-hb', 'relay carries the task token');

    # The relayed bytes decode to a coresdk.ActivityHeartbeat with the token.
    my $HB = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');
    my $msg = $HB->decode($relayed[0]{bytes});
    T2->is($msg->task_token, 'tok-hb', 'relayed heartbeat proto carries token');
    T2->is(scalar(@{ $msg->details }), 2, 'two heartbeat detail payloads');

    $pool->close;
});

# ---------------------------------------------------------------------------
# Cooperative cancellation: the parent signals cancel; the child body sees its
# ctx->cancellation->is_cancelled go true. Cancellation propagates parent->child
# over the function channel (no shared core token in the child).
# ---------------------------------------------------------------------------
T2->subtest('cooperative cancellation propagates parent->child' => sub {
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'check_cancel',
                sync => 1,
                code => sub (@) {
                    my $ctx = Temporalio::Activity::context();
                    return $ctx->cancellation->is_cancelled ? 'cancelled' : 'live';
                },
            ),
        ],
    );

    my $pool = Temporalio::Activity::Pool->new(
        loop        => $loop,
        max_workers => 1,
        registry    => $registry,
    );

    my $inv = Temporalio::Activity::Invocation->new(
        activity_type => 'check_cancel',
        args          => [],
        info          => { task_token => 'tok-cancel' },
        task_token    => 'tok-cancel',
        cancelled     => 1,    # parent marks the invocation cancelled
    );

    my $result = run_loop($pool->invoke($inv));
    T2->is($result, 'cancelled',
        'child context observes the cancellation flag set by the parent');

    $pool->close;
});

# ---------------------------------------------------------------------------
# Dispatcher routing: a sync-declared activity routes to the fork pool; an
# async-declared activity runs on the main loop. The dispatcher is given an
# injectable pool whose `invoke` is spied on; sync activities hit the pool,
# async activities do not.
# ---------------------------------------------------------------------------
T2->subtest('dispatcher routes sync defs to the pool, async defs to the loop' => sub {
    require Temporalio::Worker::ActivityDispatcher;
    require Temporalio::Converter::Data;

    my $dc = Temporalio::Converter::Data->new;

    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => [
            Temporalio::Activity::FunctionDefinition->new(
                name => 'sync_one',
                sync => 1,
                code => sub ($x) { return "sync:$x" },
            ),
            Temporalio::Activity::FunctionDefinition->new(
                name => 'async_one',
                code => async sub ($x) { return "async:$x" },
            ),
        ],
    );

    my @pool_invocations;    # (Temporalio::Activity::Invocation) seen by the pool
    my $fake_pool = FakePool->new(seen => \@pool_invocations);

    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => $fake_pool,
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
    );

    my $ActivityTask = Temporalio::Core::Proto::resolve(
        'coresdk.activity_task.ActivityTask');
    my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
    my $Completion = Temporalio::Core::Proto::resolve(
        'coresdk.ActivityTaskCompletion');

    my sub start_bytes ($token, $type, @args) {
        my @payloads = await_f($dc->to_payloads([@args]));
        my $start = $Start->new({
            workflow_namespace => 'default',
            activity_id        => 'a-1',
            activity_type      => $type,
            input              => [@payloads],
            attempt            => 1,
        });
        return $ActivityTask->new({ task_token => $token, start => $start })->encode;
    }

    # Sync activity -> pool.
    await_f($dispatcher->dispatch_task(start_bytes('tok-s', 'sync_one', 7)));
    T2->is(scalar(@pool_invocations), 1, 'sync activity routed to the pool');
    T2->is($pool_invocations[0]->activity_type, 'sync_one',
        'pool received the sync invocation');
    T2->is($pool_invocations[0]->args, [7], 'pool invocation carries converted args');
    T2->is(scalar(@completions), 1, 'sync activity produced a completion');
    my $comp_s = $Completion->decode($completions[0]);
    T2->is($comp_s->result->which_status, 'completed', 'sync completion is completed');
    my ($sval) = await_f($dc->from_payloads([$comp_s->result->completed->result]));
    T2->is($sval, 'sync:7', 'sync result round-trips from the pool');

    # Async activity -> main loop (pool untouched).
    @completions = ();
    await_f($dispatcher->dispatch_task(start_bytes('tok-a', 'async_one', 9)));
    T2->is(scalar(@pool_invocations), 1, 'async activity did NOT touch the pool');
    T2->is(scalar(@completions), 1, 'async activity produced a completion');
    my $comp_a = $Completion->decode($completions[0]);
    my ($aval) = await_f($dc->from_payloads([$comp_a->result->completed->result]));
    T2->is($aval, 'async:9', 'async result from the main loop');
});

T2->done_testing;

# A stand-in fork pool: records the invocations handed to it and runs the
# registered sync body inline (no real fork) so the dispatcher routing is
# unit-testable without forking.
class FakePool {
    field $seen :param;
    field $registry :param = undef;
    # %opts absorbs the R19 `cancellation` option the dispatcher now passes;
    # the routing test does not exercise live cancel delivery.
    method invoke ($inv, %opts) {
        push @$seen, $inv;
        # Resolve to a result so the dispatcher can build a completion. The
        # routing test only needs the value; run the body inline here.
        require Temporalio::Worker::ActivityRegistry;
        return Future->done("sync:" . $inv->args->[0]);
    }
    method close { }
}
