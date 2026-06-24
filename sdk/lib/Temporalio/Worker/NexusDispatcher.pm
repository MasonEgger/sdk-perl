# ABOUTME: Nexus task dispatcher (spec section 26.2/26.3): decodes NexusTask
# ABOUTME: bytes, routes start/cancel, runs the operation under a dynamically-
# ABOUTME: scoped Nexus context on the main loop, and builds the NexusTaskCompletion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Future ();
use Future::AsyncAwait;
use Scalar::Util ();
use Syntax::Keyword::Dynamically;

use Temporalio::Nexus ();
use Temporalio::Nexus::OperationContext ();
use Temporalio::Nexus::OperationResult ();
use Temporalio::Nexus::WorkflowHandle ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::NexusHandler ();
use Temporalio::Exception::Nexus::OperationError ();
use Temporalio::Exception::Application ();
use Temporalio::Exception::WorkflowAlreadyStarted ();

class Temporalio::Worker::NexusDispatcher {
    # Temporalio::Worker::NexusRegistry: service => { operations => {...} }.
    field $registry :param;

    # Temporalio::Converter::Data: converts operation input/result payloads and
    # codec encodes the failure proto at the worker boundary.
    field $data_converter :param;

    field $task_queue :param;
    field $client     :param = undef;
    field $loop       :param = undef;
    field $logger     :param = undef;

    # A coderef ($completion_bytes) -> Future sending the serialized
    # NexusTaskCompletion to core. Injectable so unit tests capture completions
    # without a live worker.
    field $completer :param;

    # task_token => { ... } for tasks currently running (cancel_task aborts these).
    field %running;

    # Proto classes resolved once.
    field $NexusTask;
    field $NexusTaskCompletion;
    field $Response;
    field $StartOperationResponse;
    field $StartOperationResponseSync;
    field $StartOperationResponseAsync;
    field $CancelOperationResponse;
    field $HandlerError;

    ADJUST {
        $NexusTask           = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTask');
        $NexusTaskCompletion = Temporalio::Core::Proto::resolve('coresdk.nexus.NexusTaskCompletion');
        $Response               = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.Response');
        $StartOperationResponse = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.StartOperationResponse');
        $StartOperationResponseSync  = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.StartOperationResponse.Sync');
        $StartOperationResponseAsync = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.StartOperationResponse.Async');
        $CancelOperationResponse = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.CancelOperationResponse');
        $HandlerError           = Temporalio::Core::Proto::resolve('temporal.api.nexus.v1.HandlerError');
    }

    method registry       { $registry }
    method data_converter { $data_converter }
    method is_running ($task_token) { exists $running{$task_token} ? 1 : 0 }

    # dispatch_task($task_bytes) -> Future (spec section 26.3): decode the
    # NexusTask and branch on its variant. A cancel_task aborts a tracked task;
    # a task is a server start/cancel request handled to completion.
    async method dispatch_task ($task_bytes) {
        my $task  = $NexusTask->decode($task_bytes);
        my $which = $task->which_variant // '';
        if ($which eq 'cancel_task') {
            $self->_handle_cancel_task($task->cancel_task);
            return;
        }
        if ($which eq 'task') {
            await $self->_handle_task($task);
            return;
        }
        warn "Temporalio::Worker::NexusDispatcher: unrecognized Nexus task"
           . " variant '$which' dropped\n";
        return;
    }

    # cancel_task (core-abort): cancel the tracked task and ack. Distinct from a
    # server cancel_operation request (which cancels a backing workflow).
    method _handle_cancel_task ($cancel) {
        my $entry = $running{$cancel->task_token};
        if (defined $entry && defined $entry->{cancellation}) {
            $entry->{cancellation}->();
        }
        return;
    }

    # A server task (start or cancel operation). Decodes the poll response's
    # request, routes by variant, builds + sends the NexusTaskCompletion.
    async method _handle_task ($task) {
        my $poll        = $task->task;
        my $task_token  = $poll->task_token;
        my $request     = $poll->request;
        my $req_variant = $request->which_variant // '';

        $running{$task_token} = {};

        my $completion;
        try {
            if ($req_variant eq 'start_operation') {
                $completion = await $self->_handle_start(
                    $task_token, $request, $task->endpoint);
            }
            elsif ($req_variant eq 'cancel_operation') {
                $completion = await $self->_handle_cancel_operation(
                    $task_token, $request, $task->endpoint);
            }
            else {
                Temporalio::Exception::NexusHandler->throw(
                    message => "unrecognized Nexus request variant '$req_variant'",
                    type    => 'NOT_IMPLEMENTED',
                );
            }
        }
        catch ($error) {
            $completion = await $self->_handler_error_completion($task_token, $error);
        }

        try {
            await $completer->($completion);
        }
        catch ($send_error) {
            warn "Temporalio::Worker::NexusDispatcher: sending completion for"
               . " '$task_token' failed: $send_error\n";
        }
        delete $running{$task_token};
        return;
    }

    # Start operation: look up the registered op, decode the input, run the body
    # under the dynamically-scoped Nexus context, and wrap the outcome. A sync
    # op returns a plain value -> Sync{payload}; a workflow-run op returns a
    # Nexus::WorkflowHandle -> Async{operation_token}. An OperationError ->
    # failure-carrying StartOperationResponse (spec section 26.4).
    async method _handle_start ($task_token, $request, $endpoint) {
        my $start     = $request->start_operation;
        my $service   = $start->service;
        my $operation = $start->operation;

        my $def = $registry->operation($service, $operation);
        if (!defined $def) {
            Temporalio::Exception::NexusHandler->throw(
                message => "Nexus operation '$service/$operation' is not "
                    . "registered on this worker",
                type    => 'NOT_FOUND',
            );
        }

        my $input = defined $start->payload
            ? (await $data_converter->from_payloads([$start->payload]))[0]
            : undef;

        my $info = Temporalio::Nexus::OperationInfo->new(
            service    => $service,
            operation  => $operation,
            endpoint   => $endpoint,
            task_queue => $task_queue,
        );

        my $ctx = $def->{kind} eq 'workflow_run'
            ? Temporalio::Nexus::WorkflowRunOperationContext->new(
                info => $info, client => $client, logger => $logger,
                headers => ($request->can('header') ? ($request->header // {}) : {}))
            : Temporalio::Nexus::StartOperationContext->new(
                info => $info, client => $client, logger => $logger,
                headers => ($request->can('header') ? ($request->header // {}) : {}));

        my $result;
        try {
            $result = do {
                dynamically $Temporalio::Nexus::CURRENT = $ctx;
                await $self->_invoke($def->{code}, $ctx, $input);
            };
        }
        catch ($error) {
            # A handler OperationError is an operation-level failure, not a
            # handler/infra error: it produces a failure-carrying
            # StartOperationResponse (spec section 26.4).
            if (Scalar::Util::blessed($error)
                && $error->isa('Temporalio::Exception::Nexus::OperationError'))
            {
                return await $self->_operation_error_completion($task_token, $error);
            }
            die $error;   # handler/infra error -> _handler_error_completion
        }

        return await $self->_start_success_completion(
            $task_token, $def->{kind}, $result);
    }

    # Build a Sync{payload} or Async{operation_token} completion from the
    # operation's return value.
    async method _start_success_completion ($task_token, $kind, $result) {
        my $start_resp;
        if ($kind eq 'workflow_run') {
            my $token = _operation_token_from($result);
            $start_resp = $StartOperationResponse->new({
                async_success =>
                    $StartOperationResponseAsync->new({ operation_token => $token }),
            });
        }
        else {
            # Allow a handler to return an explicit Sync result wrapper.
            my $value = (Scalar::Util::blessed($result)
                && $result->isa('Temporalio::Nexus::OperationResult::Sync'))
                ? $result->value : $result;
            my ($payload) = await $data_converter->to_payloads([$value]);
            $start_resp = $StartOperationResponse->new({
                sync_success =>
                    $StartOperationResponseSync->new({ payload => $payload }),
            });
        }
        return $self->_completion($task_token,
            completed => $Response->new({ start_operation => $start_resp }));
    }

    # Extract the operation token from a workflow-run handler's return value.
    sub _operation_token_from ($result) {
        if (Scalar::Util::blessed($result)) {
            return $result->operation_token
                if $result->isa('Temporalio::Nexus::OperationResult::Async');
            return $result->to_token
                if $result->isa('Temporalio::Nexus::WorkflowHandle');
        }
        Temporalio::Exception::NexusHandler->throw(
            message => "a :WorkflowRunOperation handler must return a "
                . "Temporalio::Nexus::WorkflowHandle",
            type    => 'INTERNAL',
        );
    }

    # Cancel operation: decode the token, cancel the backing workflow, ack.
    async method _handle_cancel_operation ($task_token, $request, $endpoint) {
        my $cancel = $request->cancel_operation;
        my $token  = $cancel->operation_token;
        if (defined $client && defined $token && length $token) {
            my $wf = Temporalio::Nexus::WorkflowHandle->from_token($token);
            my $handle = $client->get_workflow_handle($wf->workflow_id);
            await $handle->cancel;
        }
        my $cancel_resp = $CancelOperationResponse->new({});
        return $self->_completion($task_token,
            completed => $Response->new({ cancel_operation => $cancel_resp }));
    }

    # A handler OperationError -> failure-carrying StartOperationResponse: state
    # 'canceled' -> Cancelled failure, 'failed' -> Application failure (spec
    # section 26.4). The wrapped cause (or the OperationError itself) is encoded.
    async method _operation_error_completion ($task_token, $error) {
        my $cause = $error->can('cause') ? $error->cause : undef;
        my $to_encode = defined $cause ? $cause : $error;
        my $failure = await $data_converter->to_failure($to_encode);
        my $start_resp = $StartOperationResponse->new({ failure => $failure });
        return $self->_completion($task_token,
            completed => $Response->new({ start_operation => $start_resp }));
    }

    # A handler/infra error -> NexusTaskCompletion.failure carrying a
    # HandlerError (spec section 26.4). Mirrors python _exception_to_handler_error:
    # a NexusHandler passes through; Application(non_retryable)->INTERNAL;
    # WorkflowAlreadyStarted->INTERNAL non-retryable; an RpcError maps via the
    # gRPC->Nexus MUST-match table; anything else -> INTERNAL.
    async method _handler_error_completion ($task_token, $error) {
        my ($type, $retryable, $message) = $self->_to_handler_error($error);
        my $cause = (Scalar::Util::blessed($error) && $error->can('cause'))
            ? $error->cause : undef;
        my $inner = defined $cause ? $cause : $error;
        my $failure = await $data_converter->to_failure($inner);

        my %he = (error_type => $type, failure => $failure);
        if (defined $retryable) {
            $he{retry_behavior} = $retryable
                ? 'NEXUS_HANDLER_ERROR_RETRY_BEHAVIOR_RETRYABLE'
                : 'NEXUS_HANDLER_ERROR_RETRY_BEHAVIOR_NON_RETRYABLE';
        }
        my $handler_error = $HandlerError->new(\%he);
        return $self->_completion($task_token, failure_handler => $handler_error);
    }

    # Map a thrown error to ($nexus_type, $retryable_override, $message).
    # MUST-match sdk-python _exception_to_handler_error / the gRPC table.
    method _to_handler_error ($error) {
        if (Scalar::Util::blessed($error)) {
            if ($error->isa('Temporalio::Exception::NexusHandler')) {
                my $rb = $error->retry_behavior;
                my $override =
                      (defined $rb && $rb =~ /RETRYABLE\z/)     ? 1
                    : (defined $rb && $rb =~ /NON_RETRYABLE\z/) ? 0
                    :                                             undef;
                return ($error->type // 'INTERNAL', $override, "$error");
            }
            if ($error->isa('Temporalio::Exception::WorkflowAlreadyStarted')) {
                return ('INTERNAL', 0, "$error");
            }
            if ($error->isa('Temporalio::Exception::Application')) {
                # non_retryable Application -> INTERNAL non-retryable.
                my $nonret = $error->can('non_retryable')
                    && $error->non_retryable;
                return ('INTERNAL', $nonret ? 0 : undef, "$error");
            }
            if ($error->isa('Temporalio::Exception::RpcError')) {
                my ($type, $override) =
                    Temporalio::Nexus::grpc_status_to_nexus_type($error->status_name);
                return ($type, $override, "$error");
            }
        }
        return ('INTERNAL', undef, "$error");
    }

    # Build a NexusTaskCompletion. $kind is 'completed' (a Response),
    # 'failure_handler' (a HandlerError -> the `failure` field carries the
    # HandlerError's failure; we set the deprecated `error` for compat), or
    # 'ack_cancel'.
    method _completion ($task_token, $kind, $value) {
        if ($kind eq 'completed') {
            return $NexusTaskCompletion->new(
                { task_token => $task_token, completed => $value })->encode;
        }
        if ($kind eq 'failure_handler') {
            # Use the (still-supported) deprecated `error` HandlerError variant:
            # it carries error_type + retry_behavior + the inner failure, which
            # the new `failure` field (a bare Failure) cannot represent.
            return $NexusTaskCompletion->new(
                { task_token => $task_token, error => $value })->encode;
        }
        if ($kind eq 'ack_cancel') {
            return $NexusTaskCompletion->new(
                { task_token => $task_token, ack_cancel => 1 })->encode;
        }
        die "Temporalio::Worker::NexusDispatcher: unknown completion kind '$kind'\n";
    }

    # Invoke the operation callable. A sync op returns a plain value; a
    # workflow-run op returns a Future (start_workflow is async). Future->wrap
    # normalises both shapes and routes a synchronous die into the Future.
    method _invoke ($code, @args) {
        return Future->call(sub { Future->wrap($code->(@args)) });
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::NexusDispatcher - dispatch Nexus tasks to handler operations

=head1 DESCRIPTION

The Nexus dispatcher (spec section 26.2/26.3), modeled on
L<Temporalio::Worker::ActivityDispatcher>. C<dispatch_task($task_bytes)>
decodes a C<NexusTask>, routes start/cancel operation requests to the registered
handler, runs the operation under a dynamically-scoped
L<Temporalio::Nexus> context on the main loop (user code never runs on a Tokio
thread), and builds the C<NexusTaskCompletion>.

A C<:SyncOperation> return becomes C<StartOperationResponse.Sync{payload}>; a
C<:WorkflowRunOperation> return (a L<Temporalio::Nexus::WorkflowHandle>) becomes
C<StartOperationResponse.Async{operation_token}>. A handler
L<Temporalio::Exception::Nexus::OperationError> becomes a failure-carrying
C<StartOperationResponse>; any other error becomes a C<HandlerError> whose Nexus
type follows the MUST-match table in L<Temporalio::Nexus> (spec section 26.4).

=head1 CONSTRUCTOR

=head2 new

    Temporalio::Worker::NexusDispatcher->new(
        registry => ..., data_converter => ..., task_queue => ...,
        completer => sub { ... }, client => ..., logger => ...);

=head1 METHODS

=head2 dispatch_task

C<< dispatch_task($task_bytes) >> decodes and handles one Nexus task; returns a
Future that resolves once the completion is sent.

=head2 registry

The L<Temporalio::Worker::NexusRegistry>.

=head2 data_converter

The L<Temporalio::Converter::Data>.

=head2 is_running

C<< is_running($task_token) >> is true while a task is in flight.

=cut
