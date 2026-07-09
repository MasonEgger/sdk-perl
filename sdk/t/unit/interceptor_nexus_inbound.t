# ABOUTME: Unit tests for the Nexus operation INBOUND interceptor chain (spec
# ABOUTME: R73, parity finding 3): intercept_nexus_operation folds over a
# ABOUTME: handler-running root so start/cancel overrides wrap the handler
# ABOUTME: (sdk-python _interceptor.py:66-78,500-528 via _nexus.py:657-675).
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

use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Nexus::WorkflowHandle ();
use Temporalio::Worker::NexusRegistry ();
use Temporalio::Worker::NexusDispatcher ();
use Temporalio::Worker::Interceptor ();

require NexusDef::Handler;

# ---------------------------------------------------------------------------
# Fixtures FIRST: a signatured plain sub before the first `class :isa` poisons
# the 5.38 `feature 'class'` parser under Future::AsyncAwait (lessons.md
# 2026-07-09), so every helper sub below the classes may keep its signature.
# Each spy records onto a shared trace, then delegates to the next link, so the
# trace is the exact order the chain and the handler actually ran.
# ---------------------------------------------------------------------------
class SpyNexusInbound :isa(Temporalio::Worker::NexusOperationInbound) {
    field $tag   :param;
    field $trace :param;
    method execute_nexus_operation_start {
        push @$trace, "$tag:start";
        return $self->next->execute_nexus_operation_start($_[0]);
    }
    method execute_nexus_operation_cancel {
        my ($input) = @_;
        push @$trace, "$tag:cancel-before";
        return Future->wrap(
            $self->next->execute_nexus_operation_cancel($input)
        )->then(sub (@r) {
            push @$trace, "$tag:cancel-after";
            return Future->done(@r);
        });
    }
}
class SpyNexusInterceptor :isa(Temporalio::Worker::Interceptor) {
    field $tag   :param;
    field $trace :param;
    method intercept_nexus_operation {
        return SpyNexusInbound->new(next => $_[0], tag => $tag, trace => $trace);
    }
}

# A fake client whose workflow handle records its cancel call, so the cancel
# subtest can prove the real handler work runs INSIDE the override wrap.
class FakeWorkflowHandle {
    field $trace :param;
    method cancel { push @$trace, 'client:cancel'; return Future->done }
}
class FakeCancelClient {
    field $trace :param;
    method get_workflow_handle { FakeWorkflowHandle->new(trace => $trace) }
}

# Futures here resolve synchronously (in-memory converter, fake client), so
# ->get drives them. Matches t/unit/nexus_dispatch.t.
sub await_f ($f) { return $f->get }

my $NexusTask           = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTask');
my $NexusTaskCompletion = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTaskCompletion');
my $PollResp = Temporalio::Core::Proto::resolve(
    'temporal.api.workflowservice.v1.PollNexusTaskQueueResponse');
my $Request  = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.Request');
my $StartReq = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.StartOperationRequest');
my $CancelReq = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.CancelOperationRequest');

# Build a NexusTask `task` variant carrying a start_operation request.
sub start_task_bytes ($dc, $token, $service, $operation, $input) {
    my ($payload) = await_f($dc->to_payloads([$input]));
    my $start = $StartReq->new({
        service => $service, operation => $operation, payload => $payload });
    my $req  = $Request->new({ start_operation => $start });
    my $poll = $PollResp->new({ task_token => $token, request => $req });
    return $NexusTask->new({ task => $poll, endpoint => 'my-endpoint' })->encode;
}

# Build a NexusTask `task` variant carrying a cancel_operation request.
sub cancel_op_task_bytes ($token, $service, $operation, $op_token) {
    my $cancel = $CancelReq->new({
        service => $service, operation => $operation, operation_token => $op_token });
    my $req  = $Request->new({ cancel_operation => $cancel });
    my $poll = $PollResp->new({ task_token => $token, request => $req });
    return $NexusTask->new({ task => $poll, endpoint => 'my-endpoint' })->encode;
}

sub build_dispatcher (%args) {
    my $dc       = Temporalio::Converter::Data->new;
    my $registry = Temporalio::Worker::NexusRegistry->new(
        nexus_services => ['NexusDef::Handler']);
    my $completions = [];
    my $dispatcher = Temporalio::Worker::NexusDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
        %args,
    );
    return ($dispatcher, $dc, $completions);
}

sub decode_completion ($bytes) { return $NexusTaskCompletion->decode($bytes) }

sub sync_result ($dc, $completion) {
    my $start_resp = $completion->completed->start_operation;
    my ($value) = await_f($dc->from_payloads([$start_resp->sync_success->payload]));
    return $value;
}

# R73: a start interceptor override runs BEFORE the handler body, first-listed
# outermost, and the result still flows through the chain.
T2->subtest('R73: start override runs before the handler body' => sub {
    my $trace = \@NexusDef::Handler::TRACE;
    @$trace = ();
    my ($d, $dc, $comps) = build_dispatcher(interceptors => [
        SpyNexusInterceptor->new(tag => 'A', trace => $trace),
        SpyNexusInterceptor->new(tag => 'B', trace => $trace),
    ]);
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-s1', 'test-service', 'traced', 'x')));

    T2->is($trace, [ 'A:start', 'B:start', 'handler:traced' ],
        'both overrides ran before the handler body, first-listed outermost');
    T2->is(scalar(@$comps), 1, 'one completion sent');
    my $c = decode_completion($comps->[0]);
    T2->is($c->which_status, 'completed', 'the start still completes');
    T2->is(sync_result($dc, $c), 'traced:x',
        'the handler result flows back through the chain');
});

# R73: a cancel interceptor override WRAPS the handler call: the real cancel
# work (the backing-workflow cancel) runs inside the override's before/after.
T2->subtest('R73: cancel override wraps the handler call' => sub {
    my @trace;
    my ($d, $dc, $comps) = build_dispatcher(
        interceptors => [ SpyNexusInterceptor->new(tag => 'A', trace => \@trace) ],
        client       => FakeCancelClient->new(trace => \@trace),
    );
    my $op_token = Temporalio::Nexus::WorkflowHandle->new(
        namespace => 'default', workflow_id => 'op-wf-9')->to_token;
    await_f($d->dispatch_task(
        cancel_op_task_bytes('tok-c1', 'test-service', 'run-wf', $op_token)));

    T2->is(\@trace, [ 'A:cancel-before', 'client:cancel', 'A:cancel-after' ],
        'the override wraps the real backing-workflow cancel');
    my $c = decode_completion($comps->[0]);
    T2->is($c->which_status, 'completed', 'the cancel still completes');
    T2->is($c->completed->which_variant, 'cancel_operation',
        'response variant is cancel_operation');
});

# R73: the base (no interceptor) runs the handler directly with the same result.
T2->subtest('R73: no interceptor runs the handler directly, same result' => sub {
    my $trace = \@NexusDef::Handler::TRACE;
    @$trace = ();
    my ($d, $dc, $comps) = build_dispatcher();
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-b1', 'test-service', 'traced', 'x')));

    T2->is($trace, [ 'handler:traced' ],
        'only the handler ran (no interceptor entries)');
    my $c = decode_completion($comps->[0]);
    T2->is($c->which_status, 'completed', 'the start completes');
    T2->is(sync_result($dc, $c), 'traced:x',
        'the bare-handler result matches the through-the-chain result');
});

T2->done_testing;
