# ABOUTME: Unit tests for the Nexus dispatcher (spec section 26.2/26.3/26.4):
# ABOUTME: start-operation routing, Sync/Async completions, handler-error and
# ABOUTME: operation-error mapping, cancel-operation ack (T-nexus-12/13/14),
# ABOUTME: and core cancel_task abort + ack_cancel (R32, finding L20).
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

require NexusDef::Handler;

# Futures here resolve synchronously (in-memory converter, bodies park on
# nothing), so ->get drives them. Matches activity_dispatch.t.
sub await_f ($f) { return $f->get }

my $NexusTask           = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTask');
my $NexusTaskCompletion = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTaskCompletion');
my $PollResp = Temporalio::Core::Proto::resolve(
    'temporal.api.workflowservice.v1.PollNexusTaskQueueResponse');
my $Request  = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.Request');
my $StartReq = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.StartOperationRequest');
my $CancelReq = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.CancelOperationRequest');
my $CancelNexusTask = Temporalio::Core::Proto::resolve('coresdk.nexus.CancelNexusTask');

sub new_dc { Temporalio::Converter::Data->new }

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
    my $dc       = $args{data_converter} // new_dc();
    my $registry = Temporalio::Worker::NexusRegistry->new(
        nexus_services => $args{nexus_services} // ['NexusDef::Handler']);
    my $completions = $args{completions} // [];
    my $dispatcher = Temporalio::Worker::NexusDispatcher->new(
        registry       => $registry,
        data_converter => $dc,
        task_queue     => 'demo',
        completer      => sub ($bytes) {
            push @$completions, $bytes;
            return Future->done;
        },
    );
    return ($dispatcher, $dc, $completions);
}

# Decode a NexusTaskCompletion from raw bytes.
sub decode_completion ($bytes) { return $NexusTaskCompletion->decode($bytes) }

# T-nexus-12: a sync operation returns StartOperationResponse.Sync{payload}.
T2->subtest('T-nexus-12: sync operation -> Sync{payload}' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-1', 'test-service', 'say-hello', 'World')));

    T2->is(scalar(@$comps), 1, 'one completion sent');
    my $c = decode_completion($comps->[0]);
    T2->is($c->task_token, 'tok-1', 'completion carries the task token');
    T2->is($c->which_status, 'completed', 'status is completed');
    my $start_resp = $c->completed->start_operation;
    T2->is($start_resp->which_variant, 'sync_success', 'sync_success variant');
    my ($value) = await_f($dc->from_payloads([$start_resp->sync_success->payload]));
    T2->is($value, 'Hello, World!',
        'the sync payload decodes to the operation result');
});

# T-nexus-13: a workflow-run operation returns Async{operation_token}.
T2->subtest('T-nexus-13: workflow-run operation -> Async{operation_token}' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-2', 'test-service', 'run-wf', '7')));

    my $c = decode_completion($comps->[0]);
    my $start_resp = $c->completed->start_operation;
    T2->is($start_resp->which_variant, 'async_success', 'async_success variant');
    my $token = $start_resp->async_success->operation_token;
    T2->ok(length $token, 'an operation token is present');
    # The token decodes back to the backing workflow id the handler chose.
    my $h = Temporalio::Nexus::WorkflowHandle->from_token($token);
    T2->is($h->workflow_id, 'op-wf-7', 'the token references the backing workflow');
});

# T-nexus-14: a handler error -> NexusTaskCompletion.error{HandlerError} with
# the right Nexus type.
T2->subtest('T-nexus-14: handler error -> HandlerError with type' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-3', 'test-service', 'bad-request', 'x')));

    my $c = decode_completion($comps->[0]);
    T2->is($c->which_status, 'error', 'status is error (HandlerError variant)');
    T2->is($c->error->error_type, 'BAD_REQUEST',
        'handler error carries the BAD_REQUEST Nexus type');
});

# T-nexus-14: an unregistered operation -> NOT_FOUND handler error.
T2->subtest('T-nexus-14: unknown operation -> NOT_FOUND' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-4', 'test-service', 'nope', 'x')));
    my $c = decode_completion($comps->[0]);
    T2->is($c->which_status, 'error', 'status is error');
    T2->is($c->error->error_type, 'NOT_FOUND',
        'unknown operation -> NOT_FOUND handler error');
});

# T-nexus-14: an OperationError -> failure-carrying StartOperationResponse
# (NOT a HandlerError): the completion is `completed` with a start_operation
# response whose variant is `failure`.
T2->subtest('T-nexus-14: OperationError -> failure-carrying response' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-5', 'test-service', 'op-failed', 'x')));

    my $c = decode_completion($comps->[0]);
    T2->is($c->which_status, 'completed',
        'an operation error is a completed (not handler-error) response');
    my $start_resp = $c->completed->start_operation;
    T2->is($start_resp->which_variant, 'failure',
        'the start response carries a failure');
    T2->like($start_resp->failure->message, qr/boom/,
        'the failure carries the operation cause message');
});

# Cancel-operation task with no client -> ack with an empty CancelOperationResponse.
T2->subtest('cancel-operation task -> CancelOperationResponse' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    my $op_token = Temporalio::Nexus::WorkflowHandle->new(
        namespace => 'default', workflow_id => 'op-wf-9')->to_token;
    await_f($d->dispatch_task(
        cancel_op_task_bytes('tok-6', 'test-service', 'run-wf', $op_token)));

    my $c = decode_completion($comps->[0]);
    T2->is($c->which_status, 'completed', 'cancel completes');
    T2->is($c->completed->which_variant, 'cancel_operation',
        'response variant is cancel_operation');
});

# cancel_task variant (core abort) is handled without sending a completion.
T2->subtest('cancel_task variant aborts without a completion' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    my $bytes = $NexusTask->new({
        cancel_task => $CancelNexusTask->new({ task_token => 'tok-x' }),
    })->encode;
    await_f($d->dispatch_task($bytes));
    T2->is(scalar(@$comps), 0, 'no completion sent for a cancel_task');
});

# R32 (finding L20): a core cancel_task aborts the matching in-flight task: the
# operation's future is cancelled (the handler observes cancellation) and the
# task's single completion is ack_cancel. A normal op still completes and
# deregisters through the same register/deregister pair.
T2->subtest('R32: cancel_task cancels the running op and acks (finding L20)' => sub {
    my ($d, $dc, $comps) = build_dispatcher();
    my $dispatch_f = $d->dispatch_task(
        start_task_bytes($dc, 'tok-c1', 'test-service', 'park', 'x'));
    T2->ok(!$dispatch_f->is_ready, 'the parked task is still in flight');
    T2->ok($d->is_running('tok-c1'), 'the running map tracks the in-flight task');
    T2->is(scalar(@$comps), 0, 'no completion before the cancel');

    await_f($d->dispatch_task($NexusTask->new({
        cancel_task => $CancelNexusTask->new({ task_token => 'tok-c1' }),
    })->encode));

    T2->ok($NexusDef::Handler::PARKED->is_cancelled,
        'the operation future is cancelled (the handler observes cancellation)');
    T2->is(scalar(@$comps), 1, 'exactly one completion for the aborted task');
    my $c = decode_completion($comps->[0]);
    T2->is($c->task_token, 'tok-c1', 'the ack carries the task token');
    T2->is($c->which_status, 'ack_cancel', 'the completion variant is ack_cancel');
    T2->ok($c->ack_cancel, 'ack_cancel is true');
    T2->ok(!$d->is_running('tok-c1'), 'the cancelled task deregisters');
    T2->ok($dispatch_f->is_ready, 'the original dispatch future settles');

    # A second cancel_task for the same (now-finished) token is a no-op.
    await_f($d->dispatch_task($NexusTask->new({
        cancel_task => $CancelNexusTask->new({ task_token => 'tok-c1' }),
    })->encode));
    T2->is(scalar(@$comps), 1, 'a late duplicate cancel_task sends nothing');

    # Regression: a normal (uncancelled) op still completes and deregisters.
    await_f($d->dispatch_task(
        start_task_bytes($dc, 'tok-c2', 'test-service', 'say-hello', 'Still')));
    T2->is(scalar(@$comps), 2, 'the normal op sends its completion');
    T2->is(decode_completion($comps->[1])->which_status, 'completed',
        'the normal op completes as usual');
    T2->ok(!$d->is_running('tok-c2'), 'the normal op deregisters');
});

T2->done_testing;
