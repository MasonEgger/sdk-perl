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
require ActDef::PoolHeartbeatPairing;
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
# whatever await is pumping the shared IO::Async loop.
#
# Step F6: containment is not the same as relaying. A chain that dies
# delegated nothing, so nothing is recorded, which is what the async path
# already does (Context::heartbeat lets the interceptor's die propagate out
# of the body's heartbeat() call and records nothing). Python agrees on both
# of its sync executors: a thread pool re-raises the chain failure into the
# body through .result(10) (worker/_activity.py:851-853, over the
# outbound.heartbeat that _ActivityInboundImpl.init put on the context at
# 813-818), and a process pool's parent-side heartbeater logs the exception
# and ends its poll loop (worker/_activity.py:1114-1116). Neither falls back
# to recording the pre-chain value. The citation this comment carried before
# F6 (worker/_activity.py:838-844) is the heartbeat_with_context definition,
# not a try/except.
# ---------------------------------------------------------------------------
T2->subtest(
    'an ActivityOutbound interceptor that DIES in heartbeat() is contained'
        . ' to that one heartbeat: the pooled activity still completes, the'
        . ' heartbeat is DROPPED rather than relayed, and the parent loop is'
        . ' not disrupted for a LATER pooled activity sharing it' => sub
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
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
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
    T2->is(scalar(@relayed), 0,
        'neither heartbeat was recorded: a chain that dies delegated'
            . ' nothing, so the pooled path records nothing either, exactly'
            . ' as the async path does (pre-F6: the parent relayed the'
            . " child's pre-chain bytes, so this was 2)");
    T2->is(scalar(@warnings), 2,
        'each dropped heartbeat warned once');
    T2->like($warnings[0] // '',
        qr/ActivityOutbound heartbeat chain failed for token tok-throw-1/,
        'the warning names the chain failure and the token it dropped');
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

# ---------------------------------------------------------------------------
# Step F6 (spec "F6: Fork-pool frame pairing must be token-exact"): the child
# sends the raw details ('hbd') and the encoded bytes ('hb') as two frames on
# one ordered stream, and the parent pairs them by parking the details until
# the bytes arrive. Pre-F6, Context::_record_heartbeat called the details
# recorder BEFORE encode_heartbeat_bytes, so a heartbeat whose encode died
# left its details parked with no 'hb' of its own; the next 'hb' that arrived
# without details of its own (the Storable-freeze-failure shape the
# unfreezable subtest above covers) paired with those stale details, and the
# chain re-encoded the EARLIER heartbeat's args in place of the later one's.
#
# ActDef::PoolHeartbeatPairing records exactly that sequence: a detail that
# freezes but does not convert, then one that converts but does not freeze,
# then one that survives both.
# ---------------------------------------------------------------------------
T2->subtest(
    'a heartbeat whose encode fails does not leave its details parked for a'
        . ' LATER heartbeat to pair with' => sub
{
    my @trace;
    my @relayed;

    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::ActivityRegistry->new(
        activities => ['ActDef::PoolHeartbeatPairing']);
    my $pool     = Temporalio::Activity::Pool->new(
        loop            => $loop,
        max_workers     => 1,
        registry        => Temporalio::Worker::ActivityRegistry->new(
            activities => ['ActDef::PoolHeartbeatPairing']),
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
        interceptors   => [ HeartbeatSpyInterceptor->new(trace => \@trace) ],
    );

    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-pairing',
        activity_type      => 'PoolHeartbeatPairing',
        input              => [],
        attempt            => 1,
    });
    run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
        task_token => 'tok-pairing', start => $start,
    })->encode));

    T2->is(scalar(@completions), 1, 'one completion sent');
    my $comp = $Completion->decode($completions[0]);
    T2->is($comp->result->which_status, 'completed',
        'the activity completed: a detail the converter rejects fails only'
            . ' that heartbeat, and the body caught it');

    my @heartbeat_events = grep { $_->{op} eq 'heartbeat' } @trace;
    T2->is(scalar(@heartbeat_events), 1,
        'the chain observed exactly ONE heartbeat: the only one whose raw'
            . ' details and encoded bytes BOTH crossed the channel'
            . ' (pre-F6: 2, the extra one being heartbeat 1 details paired'
            . " with heartbeat 2's bytes)");
    if (@heartbeat_events) {
        T2->is($heartbeat_events[0]{args}, [ 'third-detail' ],
            'the observed heartbeat carries its OWN args, never an earlier'
                . " heartbeat's parked details");
    }
    T2->is(scalar(grep { ref $_->{args}[0] eq 'SCALAR' } @heartbeat_events), 0,
        'heartbeat 1 never reached the chain at all: its encode failed, so'
            . ' it was never recorded on any path');

    # Both surviving 'hb' frames still reach the real relay, each carrying
    # its own payload: heartbeat 2 through the direct-bytes fallback (its
    # raw details were lost to the freeze failure) and heartbeat 3 through
    # the chain root's re-encode.
    T2->is(scalar(@relayed), 2,
        'both heartbeats that produced bytes were recorded');
    my @decoded = map {
        my $hb = $Heartbeat->decode($_->{bytes});
        $dc->payload_converter->from_payload($hb->details->[0]);
    } @relayed;
    T2->is(\@decoded, [ 'second-detail', 'third-detail' ],
        'each relayed heartbeat carries its own detail, in order'
            . " (pre-F6: heartbeat 2's frame re-encoded heartbeat 1's args)");
});

# ---------------------------------------------------------------------------
# Step F6: the hold-at-accept variant of the teardown race above. That one
# arms the hold AFTER 'start' has registered %token_conn, so the rejected
# `unless defined $token_conn{$token}` reply-time guard would have passed it
# too. Holding at ACCEPT instead means no frame on the connection is ever
# drained before the reply lands, so %token_conn is still EMPTY for this
# token at reply time. This is the ordering the child's own control_connected
# flag exists for (Pool.pm _child_dispatch), and the only one that tells the
# two candidate guards apart.
# ---------------------------------------------------------------------------
T2->subtest(
    'a pooled heartbeat still runs the outbound chain when the reply pipe'
        . ' completes before even the "start" frame has been drained' => sub
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

    # Arm the hold at ACCEPT: the child's connection is accepted and then
    # held before its first read-ready, so 'start' never registers
    # %token_conn and every frame sits unread while invoke() awaits the
    # reply pipe.
    $pool->_hold_control_drain_at_accept;

    my $start = $Start->new({
        workflow_namespace => 'default',
        activity_id        => 'a-accept-race',
        activity_type      => 'PoolHeartbeatIntercepted',
        input              => [],
        attempt            => 1,
    });
    run_to_ready($dispatcher->dispatch_task($ActivityTask->new({
        task_token => 'tok-accept-race', start => $start,
    })->encode));

    T2->is(scalar(@completions), 1,
        'the activity completed via the reply pipe while the control socket'
            . ' was still held at accept');
    T2->is(scalar(@trace), 0,
        'nothing drained yet: not even the "start" frame, so %token_conn is'
            . ' empty for this token at reply time');

    $pool->_release_control_drain;

    my @heartbeat_events = grep { $_->{op} eq 'heartbeat' } @trace;
    T2->is(scalar(@heartbeat_events), 1,
        'the outbound chain still observed the heartbeat: the reply-time'
            . ' cleanup keys off the CHILD\'s control_connected report, not'
            . ' off parent-side drain state (a %token_conn guard would have'
            . ' deleted the chain here)');
    if (@heartbeat_events) {
        T2->is($heartbeat_events[0]{args}, [ { pct => 50 }, 'halfway' ],
            'the interceptor saw the STRUCTURED Perl-level details');
    }

    my @ops = map { $_->{op} } @trace;
    T2->is(\@ops, [ 'heartbeat', 'relay' ],
        'the outbound chain ran BEFORE the heartbeat reached core');
});

T2->done_testing;
