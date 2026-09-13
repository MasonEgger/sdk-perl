# ABOUTME: RED/GREEN for step I7 direction B (closes GitHub #7 half B): a
# ABOUTME: heartbeat recorded inside a pooled (fork) sync activity must reach
# ABOUTME: the PARENT-side ActivityOutbound interceptor chain with the
# ABOUTME: STRUCTURED (Perl-level) details the body passed, not opaque bytes,
# ABOUTME: and the real heartbeat_relay must still receive the serialized
# ABOUTME: frame AFTER the chain runs. Python parity: sdk-python routes pooled
# ABOUTME: sync-activity heartbeats parent-side through
# ABOUTME: register_heartbeater(ctx.heartbeat) (worker/_activity.py:857-865),
# ABOUTME: itself wrapped by ActivityOutboundInterceptor.heartbeat
# ABOUTME: (_interceptor.py:154). Today (pre-fix) the pool relays only
# ABOUTME: already-serialized bytes (Pool.pm _on_control_frame 'hb' case),
# ABOUTME: so nothing chain-shaped runs parent-side (Context.pm ~:59-71
# ABOUTME: deviation note, ActivityDispatcher.pm ~:251-256).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use File::Temp ();
use FindBin ();
use Time::HiRes ();

use lib "$FindBin::Bin/../lib";

use Future ();
use Future::AsyncAwait;
use IO::Async::Loop ();

use Temporalio::Activity::Pool ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Worker::Interceptor ();

require ActDef::PoolHeartbeatIntercepted;
require ActDef::PoolHeartbeatUnfreezable;

# ---------------------------------------------------------------------------
# Fixtures: the SAME outbound-wrapper install shape as
# t/unit/interceptor_activity_outbound.t (the async-path R72 precedent).
# Classes declared before any signatured helper sub (F::AA parser rule,
# lessons.md 2026-07-09); methods signature-less.
# ---------------------------------------------------------------------------
class TaggingActivityOutbound :isa(Temporalio::Worker::ActivityOutbound) {
    field $trace :param;
    method heartbeat {
        push @$trace, { op => 'heartbeat', args => [ @{ $_[0]->args } ] };
        return $self->next->heartbeat($_[0]);
    }
}
class WrappingActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $trace :param;
    method init {
        return $self->next->init(
            TaggingActivityOutbound->new(next => $_[0], trace => $trace));
    }
}
class HeartbeatSpyInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $trace :param;
    method intercept_activity {
        return WrappingActivityInbound->new(next => $_[0], trace => $trace);
    }
}

# --- fix-loop iter 1 warn fixtures ------------------------------------------
# temporal.interceptor-exception-containment: an ActivityOutbound that DIES
# instead of delegating, so the parent's 'hb' handler must contain the throw
# to this one heartbeat rather than let it escape the read-ready callback.
class ThrowingActivityOutbound :isa(Temporalio::Worker::ActivityOutbound) {
    field $trace :param;
    method heartbeat {
        push @$trace, { op => 'heartbeat-attempt', args => [ @{ $_[0]->args } ] };
        die "boom: interceptor heartbeat failure\n";
    }
}
class ThrowingWrappingActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $trace :param;
    method init {
        return $self->next->init(
            ThrowingActivityOutbound->new(next => $_[0], trace => $trace));
    }
}
class ThrowingHeartbeatInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $trace :param;
    method intercept_activity {
        return ThrowingWrappingActivityInbound->new(next => $_[0], trace => $trace);
    }
}

# temporal.heartbeat-chain-rewrite-parity: an ActivityOutbound that REWRITES
# the heartbeat args before delegating, so the relayed bytes must reflect the
# rewrite (parent-side re-encode), not the child's pre-rewrite bytes.
class RewritingActivityOutbound :isa(Temporalio::Worker::ActivityOutbound) {
    field $trace :param;
    method heartbeat {
        push @$trace, { op => 'heartbeat', args => [ @{ $_[0]->args } ] };
        $_[0]->args([ 'rewritten-by-interceptor' ]);
        return $self->next->heartbeat($_[0]);
    }
}
class RewritingWrappingActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $trace :param;
    method init {
        return $self->next->init(
            RewritingActivityOutbound->new(next => $_[0], trace => $trace));
    }
}
class RewritingHeartbeatInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $trace :param;
    method intercept_activity {
        return RewritingWrappingActivityInbound->new(next => $_[0], trace => $trace);
    }
}

my $loop = IO::Async::Loop->new;

sub run_to_ready ($f, $timeout = 40) {
    $loop->await(Future->wait_any($f->without_cancel,
        $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n" unless $f->is_ready;
    # temporal.heartbeat-chain-teardown-race: the reply pipe (this future)
    # and the control socket ('hbd'/'hb'/'end' frames) are independently
    # ordered channels, so the reply can resolve while a control frame the
    # child already wrote is still sitting undrained in the parent's read
    # buffer. A handful of non-blocking pumps gives the loop a chance to
    # service that already-arrived data before a caller inspects a
    # heartbeat_relay or outbound-chain trace built from it. This does not
    # mask a production bug: Pool.pm's own teardown (the 'end' case in
    # _on_control_frame, _close_conn) is correct regardless of how late a
    # frame drains; this is purely about giving THIS TEST'S assertions a
    # fair look at side effects that may still be in flight.
    $loop->loop_once(0) for 1 .. 50;
    return $f;
}

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.ActivityTaskCompletion');
my $Heartbeat = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');

T2->subtest(
    'pooled heartbeat runs the parent-side outbound chain with structured'
        . ' details, then still reaches the real relay' => sub
{
    my @trace;      # outbound-chain observations, in arrival order
    my @relayed;    # parent-side heartbeat_relay (the "real" FFI call) calls

    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::PoolHeartbeatIntercepted']);
    my $pool     = Temporalio::Activity::Pool->new(
        loop            => $loop,
        max_workers     => 1,
        registry        => Temporalio::Worker::ActivityRegistry->new(
            activities => ['ActDef::PoolHeartbeatIntercepted']),
        heartbeat_relay => sub ($token, $bytes) {
            push @relayed, { token => $token, bytes => $bytes };
            push @trace, { op => 'relay', token => $token };
            return undef;
        },
    );

    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => $pool,
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
        interceptors   => [ HeartbeatSpyInterceptor->new(trace => \@trace) ],
    );

    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-1',
        activity_type      => 'PoolHeartbeatIntercepted',
        input              => [],
        attempt            => 1,
    });
    run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
        task_token => 'tok-pool-hb', start => $start,
    })->encode));

    T2->is(scalar(@completions), 1, 'one completion sent');
    my $comp = $Completion->decode($completions[0]);
    T2->is($comp->result->which_status, 'completed', 'activity completed');

    # The interceptor observed the STRUCTURED (Perl-level) details, not
    # opaque bytes: a hashref and a string, exactly as the body passed them
    # (ActDef::PoolHeartbeatIntercepted->run heartbeats { pct => 50 },
    # 'halfway').
    my @heartbeat_events = grep { $_->{op} eq 'heartbeat' } @trace;
    T2->is(scalar(@heartbeat_events), 1,
        'the outbound chain observed exactly one heartbeat'
            . ' (pre-fix: the pool relays only bytes, nothing chain-shaped'
            . ' runs parent-side, so this is 0)');
    if (@heartbeat_events) {
        T2->is($heartbeat_events[0]{args}, [ { pct => 50 }, 'halfway' ],
            'the interceptor saw the STRUCTURED Perl-level details, not'
                . ' a serialized proto');
    }

    # The real relay still received the serialized heartbeat AFTER the chain
    # ran (order asserted via @trace: 'heartbeat' before 'relay').
    T2->is(scalar(@relayed), 1, 'the real heartbeat_relay was still invoked');
    if (@relayed) {
        T2->is($relayed[0]{token}, 'tok-pool-hb',
            'the relay carries the invocation task token');
        my $hb = $Heartbeat->decode($relayed[0]{bytes});
        T2->is($hb->task_token, 'tok-pool-hb',
            'the relayed heartbeat proto carries the task token');
        T2->is(scalar(@{ $hb->details // [] }), 2,
            'the relayed heartbeat proto carries both detail payloads');
    }

    my @ops = map { $_->{op} } @trace;
    T2->is(\@ops, [ 'heartbeat', 'relay' ],
        'the outbound chain ran BEFORE the heartbeat reached core'
            . ' (chain-then-forward, not the reverse)');
});

# ---------------------------------------------------------------------------
# Fix-loop iter 1, temporal.interceptor-exception-containment (warn): an
# ActivityOutbound that DIES in heartbeat() must be contained to that one
# heartbeat, not escape Pool's _drain_control read-ready callback and abort
# whatever await is pumping the shared IO::Async loop (sdk-python parity:
# worker/_activity.py:838-844 never lets a chain failure reach the loop).
# ---------------------------------------------------------------------------
T2->subtest(
    'an ActivityOutbound interceptor that DIES in heartbeat() is contained'
        . ' to that one heartbeat: the pooled activity still completes, the'
        . ' bytes still relay via the fallback, and the parent loop is not'
        . ' disrupted for a LATER pooled activity sharing it' => sub
{
    my @trace;
    my @relayed;

    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::PoolHeartbeatIntercepted']);
    my $pool     = Temporalio::Activity::Pool->new(
        loop            => $loop,
        max_workers     => 1,
        registry        => Temporalio::Worker::ActivityRegistry->new(
            activities => ['ActDef::PoolHeartbeatIntercepted']),
        heartbeat_relay => sub ($token, $bytes) {
            push @relayed, { token => $token, bytes => $bytes };
            return undef;
        },
    );

    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => $pool,
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
        interceptors   => [ ThrowingHeartbeatInterceptor->new(trace => \@trace) ],
    );

    # Two invocations, one worker: the second dispatch only completes if the
    # first's interceptor throw did not wedge or crash the shared loop.
    for my $token (qw(tok-throw-1 tok-throw-2)) {
        my $start = $Start->new({
            workflow_namespace => 'default',
            activity_id        => $token,
            activity_type      => 'PoolHeartbeatIntercepted',
            input              => [],
            attempt            => 1,
        });
        run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
            task_token => $token, start => $start,
        })->encode));
    }

    T2->is(scalar(@completions), 2,
        'both activities completed despite the interceptor dying on every'
            . ' heartbeat (pre-fix: the throw escapes _on_control_frame and'
            . ' this is fewer than 2, or the run dies outright)');
    for my $bytes (@completions) {
        my $comp = $Completion->decode($bytes);
        T2->is($comp->result->which_status, 'completed',
            'each completion reports success, not the interceptor error');
    }

    T2->is(scalar(grep { $_->{op} eq 'heartbeat-attempt' } @trace), 2,
        'the throwing interceptor ran for BOTH heartbeats: the first throw'
            . ' did not prevent the second activity from dispatching');
    T2->is(scalar(@relayed), 2,
        'both heartbeats still reached the real relay via the fallback');
});

# ---------------------------------------------------------------------------
# Fix-loop iter 1, temporal.storable-freeze-heartbeat-details (warn): a
# heartbeat detail Storable cannot freeze (a `feature 'class'` instance) must
# not crash the whole pooled activity over the hbd relay, which is
# documented as best-effort.
# ---------------------------------------------------------------------------
T2->subtest(
    'a heartbeat detail Storable cannot freeze does not crash the pooled'
        . ' activity: the hbd relay is best-effort, the bytes still reach'
        . ' the real relay, and the interceptor simply does not observe'
        . ' that heartbeat' => sub
{
    my @trace;
    my @relayed;

    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::PoolHeartbeatUnfreezable']);
    my $pool     = Temporalio::Activity::Pool->new(
        loop            => $loop,
        max_workers     => 1,
        registry        => Temporalio::Worker::ActivityRegistry->new(
            activities => ['ActDef::PoolHeartbeatUnfreezable']),
        heartbeat_relay => sub ($token, $bytes) {
            push @relayed, { token => $token, bytes => $bytes };
            return undef;
        },
    );

    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => $pool,
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
        interceptors   => [ HeartbeatSpyInterceptor->new(trace => \@trace) ],
    );

    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-unfreezable',
        activity_type      => 'PoolHeartbeatUnfreezable',
        input              => [],
        attempt            => 1,
    });
    run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
        task_token => 'tok-unfreezable', start => $start,
    })->encode));

    T2->is(scalar(@completions), 1,
        'the activity completed despite heartbeating an unfreezable detail'
            . ' (pre-fix: Storable::freeze dies in the child and the whole'
            . ' activity fails)');
    my $comp = $Completion->decode($completions[0]);
    T2->is($comp->result->which_status, 'completed', 'activity completed');

    T2->is(scalar(grep { $_->{op} eq 'heartbeat' } @trace), 0,
        'the outbound chain did NOT observe this heartbeat: its hbd frame'
            . ' was lost to the freeze failure, so the parent falls back'
            . ' to relaying the bytes directly');
    T2->is(scalar(@relayed), 1,
        'the real relay still received the heartbeat bytes: the paired hb'
            . ' frame is unaffected by the hbd freeze failure');
    if (@relayed) {
        T2->is($relayed[0]{token}, 'tok-unfreezable',
            'the relay carries the invocation task token');
    }
});

# ---------------------------------------------------------------------------
# Fix-loop iter 1, temporal.heartbeat-chain-rewrite-parity (warn): an
# ActivityOutbound interceptor that REWRITES heartbeat args must be honored
# on the pooled path exactly as it already is on the async path
# (Context::heartbeat re-encodes $_[0]->args at the chain root).
# ---------------------------------------------------------------------------
T2->subtest(
    'an ActivityOutbound interceptor that REWRITES heartbeat args on the'
        . ' pooled path is honored: the relayed bytes decode to the'
        . ' REWRITTEN details, not the bytes the child pre-encoded' => sub
{
    my @trace;
    my @relayed;

    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::PoolHeartbeatIntercepted']);
    my $pool     = Temporalio::Activity::Pool->new(
        loop            => $loop,
        max_workers     => 1,
        registry        => Temporalio::Worker::ActivityRegistry->new(
            activities => ['ActDef::PoolHeartbeatIntercepted']),
        data_converter  => $dc,
        heartbeat_relay => sub ($token, $bytes) {
            push @relayed, { token => $token, bytes => $bytes };
            return undef;
        },
    );

    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => $pool,
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
        interceptors   => [ RewritingHeartbeatInterceptor->new(trace => \@trace) ],
    );

    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-rewrite',
        activity_type      => 'PoolHeartbeatIntercepted',
        input              => [],
        attempt            => 1,
    });
    run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
        task_token => 'tok-rewrite', start => $start,
    })->encode));

    T2->is(scalar(@completions), 1, 'the activity completed');
    T2->is(scalar(@relayed), 1, 'the real relay was invoked once');
    if (@relayed) {
        my $hb = $Heartbeat->decode($relayed[0]{bytes});
        T2->is(scalar(@{ $hb->details // [] }), 1,
            'the relayed heartbeat carries ONE detail: the interceptor'
                . ' rewrote args down to a single-element list (pre-fix:'
                . ' the pooled root ignores the rewrite and relays the'
                . ' child pre-encoded original, which carries 2 details)');
        if (@{ $hb->details // [] }) {
            my $decoded = $dc->payload_converter->from_payload(
                $hb->details->[0]);
            T2->is($decoded, 'rewritten-by-interceptor',
                'the relayed bytes decode to the REWRITTEN detail');
        }
    }
});

# ---------------------------------------------------------------------------
# Fix-loop iter 3, temporal.heartbeat-chain-teardown-race (block): the reply
# pipe (IO::Async::Function's own IPC) and the control socket ('hbd'/'hb'/
# 'end' frames) are two independently-ordered channels. invoke() used to
# delete %token_outbound unconditionally when the reply pipe completed; when
# the reply arrived BEFORE the control socket's 'hb' frame drained, that
# delete ran first and the chain silently did not run for the heartbeat
# still sitting in the control socket's buffer. Forced deterministically via
# Pool's test-only _hold_control_drain/_release_control_drain hooks (holding
# right after 'start' registers %token_conn, so the guard's precondition is
# still met) rather than relying on load-dependent scheduler timing.
# ---------------------------------------------------------------------------
T2->subtest(
    'a pooled heartbeat still runs the outbound chain when the reply pipe'
        . ' completes BEFORE the paired hbd/hb/end control frames drain' => sub
{
    my @trace;
    my @relayed;

    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::PoolHeartbeatIntercepted']);
    my $pool     = Temporalio::Activity::Pool->new(
        loop            => $loop,
        max_workers     => 1,
        registry        => Temporalio::Worker::ActivityRegistry->new(
            activities => ['ActDef::PoolHeartbeatIntercepted']),
        heartbeat_relay => sub ($token, $bytes) {
            push @relayed, { token => $token, bytes => $bytes };
            push @trace, { op => 'relay', token => $token };
            return undef;
        },
    );

    my @completions;
    my $dispatcher = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        loop           => $loop,
        pool           => $pool,
        completer      => sub ($bytes) { push @completions, $bytes; Future->done },
        interceptors   => [ HeartbeatSpyInterceptor->new(trace => \@trace) ],
    );

    # Arm the hold BEFORE dispatching: the child's 'start' frame will
    # register %token_conn as usual, then pause further draining on that
    # connection, so 'hbd'/'hb'/'end' sit unread while invoke() awaits the
    # reply pipe.
    $pool->_hold_control_drain;

    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-race',
        activity_type      => 'PoolHeartbeatIntercepted',
        input              => [],
        attempt            => 1,
    });
    run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
        task_token => 'tok-race', start => $start,
    })->encode));

    T2->is(scalar(@completions), 1,
        'the activity completed via the reply pipe even though the control'
            . ' socket frames are still held, unread, by the parent');
    T2->is(scalar(@trace), 0,
        'nothing has been relayed or chain-observed yet: the hbd/hb/end'
            . ' frames are still sitting unread in the control socket'
            . ' buffer when invoke() resolved');

    # Release the hold: drain the buffered 'hbd'/'hb'/'end' frames now, well
    # after the reply pipe already completed.
    $pool->_release_control_drain;

    my @heartbeat_events = grep { $_->{op} eq 'heartbeat' } @trace;
    T2->is(scalar(@heartbeat_events), 1,
        'the outbound chain still observed the heartbeat even though the'
            . ' reply pipe resolved before the control frames drained'
            . ' (pre-fix: invoke() deleted the outbound chain unconditionally'
            . ' at reply time, so this is 0)');
    if (@heartbeat_events) {
        T2->is($heartbeat_events[0]{args}, [ { pct => 50 }, 'halfway' ],
            'the interceptor saw the STRUCTURED Perl-level details');
    }

    T2->is(scalar(@relayed), 1, 'the real heartbeat_relay was still invoked');

    my @ops = map { $_->{op} } @trace;
    T2->is(\@ops, [ 'heartbeat', 'relay' ],
        'the outbound chain ran BEFORE the heartbeat reached core, even'
            . ' under reply-before-drain ordering'
            . ' (pre-fix: ops omits heartbeat, or is out of order)');
});

T2->done_testing;
