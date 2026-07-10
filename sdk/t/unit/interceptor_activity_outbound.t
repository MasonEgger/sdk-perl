# ABOUTME: Unit tests for the activity-OUTBOUND interceptor chain (spec R72,
# ABOUTME: parity finding 2): an outbound wrapper installed via ActivityInbound
# ABOUTME: init(outbound) must observe/override the body's heartbeat and info
# ABOUTME: calls, and the base (no interceptor) must still heartbeat through.
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

use Temporalio::Activity ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::ActivityRegistry ();
use Temporalio::Worker::ActivityDispatcher ();
use Temporalio::Worker::Interceptor ();

# ---------------------------------------------------------------------------
# Fixtures. The install mechanism under test is Python's
# (worker/_activity.py:709-713): the dispatcher folds the inbound chain, calls
# inbound->init(root outbound), and each interceptor inbound may WRAP the
# outbound it receives before delegating init down-chain; the context then
# routes the body's heartbeat()/info() through whatever reached the root
# inbound (worker/_interceptor.py:135-156). Classes are declared before any
# signatured helper sub (F::AA parser rule, lessons.md 2026-07-09), methods
# are signature-less, and Test2 helpers use the T2-> form.
# ---------------------------------------------------------------------------

# The outbound wrapper: tags each observed heartbeat (with its details, which
# ride the Input's writable `args` field, Python's *details) and info call
# onto the shared trace, then delegates — unless `swallow` is set, in which
# case heartbeat returns WITHOUT delegating (the override fires INSTEAD of
# the context's real recording).
class TaggingActivityOutbound :isa(Temporalio::Worker::ActivityOutbound) {
    field $tag     :param;
    field $trace   :param;
    field $swallow :param = 0;
    method heartbeat {
        push @$trace, "$tag:heartbeat:" . join(',', @{ $_[0]->args });
        return if $swallow;
        return $self->next->heartbeat($_[0]);
    }
    method info {
        push @$trace, "$tag:info";
        return $self->next->info($_[0]);
    }
}

# The inbound whose init wraps the received outbound (Python
# ActivityInboundInterceptor.init parity) before delegating down-chain.
class WrappingActivityInbound :isa(Temporalio::Worker::ActivityInbound) {
    field $tag     :param;
    field $trace   :param;
    field $swallow :param = 0;
    method init {
        return $self->next->init(TaggingActivityOutbound->new(
            next => $_[0], tag => $tag, trace => $trace, swallow => $swallow));
    }
}

class ActivityOutboundInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $tag     :param;
    field $trace   :param;
    field $swallow :param = 0;
    method intercept_activity {
        return WrappingActivityInbound->new(
            next => $_[0], tag => $tag, trace => $trace, swallow => $swallow);
    }
}

# A minimal fake client (mirrors t/unit/activity_dispatch.t).
class FakeClient {
    field $data_converter :param;
    field $namespace      :param = 'default';
    field $identity       :param = 'pid@host';
    method data_converter { $data_converter }
    method namespace      { $namespace }
    method identity       { $identity }
}

# --- helpers ----------------------------------------------------------------

my $loop = IO::Async::Loop->new;
sub await_f ($f) { return $f->get }

my $ActivityTask = Temporalio::Core::Proto::resolve(
    'coresdk.activity_task.ActivityTask');
my $Start = Temporalio::Core::Proto::resolve('coresdk.activity_task.Start');
my $WorkflowExecution = Temporalio::Core::Proto::resolve(
    'temporal.api.common.v1.WorkflowExecution');
my $Completion = Temporalio::Core::Proto::resolve(
    'coresdk.ActivityTaskCompletion');
my $Heartbeat = Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat');

sub start_task_bytes ($dc, $token, $type, @args) {
    my @payloads = await_f($dc->to_payloads([@args]));
    my $start = $Start->new({
        workflow_namespace => 'default',
        workflow_type      => 'GreetWorkflow',
        workflow_execution => $WorkflowExecution->new({
            workflow_id => 'wf-1', run_id => 'run-1' }),
        activity_id   => 'act-1',
        activity_type => $type,
        input         => [@payloads],
        attempt       => 1,
    });
    return $ActivityTask->new({ task_token => $token, start => $start })->encode;
}

# Build a dispatcher over the given activities + interceptors; returns the
# dispatcher plus the completion- and heartbeat-capture arrayrefs.
sub build_dispatcher (%args) {
    my $dc          = Temporalio::Converter::Data->new;
    my $registry    = Temporalio::Worker::ActivityRegistry->new(
        activities => $args{activities});
    my $completions = [];
    my $heartbeats  = [];
    my $dispatcher  = Temporalio::Worker::ActivityDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        client         => FakeClient->new(data_converter => $dc),
        loop           => $loop,
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
        heartbeat_recorder => sub ($bytes) {
            push @$heartbeats, $bytes;
            return undef;
        },
        interceptors => $args{interceptors} // [],
    );
    return ($dispatcher, $dc, $completions, $heartbeats);
}

# An async activity body that heartbeats once through the functional surface.
sub beat_definition () {
    return Temporalio::Activity::FunctionDefinition->new(
        name => 'beat',
        code => async sub (@) {
            Temporalio::Activity::heartbeat('ping');
            return 'ok';
        },
    );
}

# An async activity body that returns its own activity_type read via info().
sub whoami_definition () {
    return Temporalio::Activity::FunctionDefinition->new(
        name => 'whoami',
        code => async sub (@) {
            return Temporalio::Activity::info()->{activity_type};
        },
    );
}

sub completed_value ($dc, $completion_bytes) {
    my $comp = $Completion->decode($completion_bytes);
    return undef unless $comp->result->which_status eq 'completed';
    my ($value) = await_f(
        $dc->from_payloads([ $comp->result->completed->result ]));
    return $value;
}

# ---------------------------------------------------------------------------
# An interceptor's outbound heartbeat override fires when the body calls
# heartbeat (spec R72 acceptance criterion; fails against the unwired base,
# where init is never called and the wrapper never observes the call), and a
# delegating override still reaches the context's real recording.
# ---------------------------------------------------------------------------
T2->subtest('outbound heartbeat override fires and delegates to the recorder' => sub {
    my @trace;
    my ($dispatcher, $dc, $completions, $heartbeats) = build_dispatcher(
        activities   => [ beat_definition() ],
        interceptors =>
            [ ActivityOutboundInterceptor->new(tag => 'A', trace => \@trace) ],
    );

    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-hb', 'beat')));

    T2->is(\@trace, ['A:heartbeat:ping'],
        'the outbound wrapper observed the heartbeat with its details');
    T2->is(scalar(@$heartbeats), 1,
        'the delegating override still reached the real recorder');
    my $hb = $Heartbeat->decode($heartbeats->[0]);
    T2->is($hb->task_token, 'tok-hb', 'the recorded heartbeat kept the token');
    my ($detail) = await_f($dc->from_payloads([ $hb->details->[0] ]));
    T2->is($detail, 'ping', 'the recorded heartbeat kept the details');
    T2->is(completed_value($dc, $completions->[0]), 'ok',
        'the activity still completed through the chain');
});

# ---------------------------------------------------------------------------
# A swallowing override fires INSTEAD of the context recording: nothing
# reaches the recorder.
# ---------------------------------------------------------------------------
T2->subtest('swallowing outbound heartbeat override replaces the recording' => sub {
    my @trace;
    my ($dispatcher, $dc, $completions, $heartbeats) = build_dispatcher(
        activities   => [ beat_definition() ],
        interceptors => [ ActivityOutboundInterceptor->new(
            tag => 'A', trace => \@trace, swallow => 1) ],
    );

    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-swallow', 'beat')));

    T2->is(\@trace, ['A:heartbeat:ping'], 'the override observed the call');
    T2->is(scalar(@$heartbeats), 0,
        'the swallowed heartbeat never reached the recorder');
    T2->is(completed_value($dc, $completions->[0]), 'ok',
        'the activity still completed');
});

# ---------------------------------------------------------------------------
# An outbound info override observes the body's info() call, and the real
# info still comes back through the chain root.
# ---------------------------------------------------------------------------
T2->subtest('outbound info override observes the info call' => sub {
    my @trace;
    my ($dispatcher, $dc, $completions) = build_dispatcher(
        activities   => [ whoami_definition() ],
        interceptors =>
            [ ActivityOutboundInterceptor->new(tag => 'A', trace => \@trace) ],
    );

    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-info', 'whoami')));

    T2->is(\@trace, ['A:info'], 'the outbound wrapper observed the info call');
    T2->is(completed_value($dc, $completions->[0]), 'whoami',
        'the real info came back through the chain root');
});

# ---------------------------------------------------------------------------
# The base (no interceptor) still heartbeats through to the context: the
# chain root alone must not change behavior.
# ---------------------------------------------------------------------------
T2->subtest('base (no interceptor) heartbeats through to the recorder' => sub {
    my ($dispatcher, $dc, $completions, $heartbeats) = build_dispatcher(
        activities => [ beat_definition() ],
    );

    await_f($dispatcher->dispatch_task(
        start_task_bytes($dc, 'tok-base', 'beat')));

    T2->is(scalar(@$heartbeats), 1, 'the heartbeat reached the recorder');
    my $hb = $Heartbeat->decode($heartbeats->[0]);
    my ($detail) = await_f($dc->from_payloads([ $hb->details->[0] ]));
    T2->is($detail, 'ping', 'with the un-mutated details');
    T2->is(completed_value($dc, $completions->[0]), 'ok',
        'and the activity completed');
});

T2->done_testing;
