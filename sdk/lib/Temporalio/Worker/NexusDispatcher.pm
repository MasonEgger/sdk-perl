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
use Temporalio::Worker::Interceptor ();
use Temporalio::Worker::_RootNexusOperationInbound ();
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

    # The combined worker interceptor list (client-supplied then
    # worker-supplied, outermost first), folded over a handler-running root on
    # every start/cancel (spec R73, parity finding 3; sdk-python
    # _interceptor.py:66-78,500-528 via _nexus.py:657-675).
    field $interceptors :param = [];

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

    # cancel_task (core-abort): abort the tracked task. Distinct from a server
    # cancel_operation request (which cancels a backing workflow). Fix for
    # finding L20 (%running held no abort mechanism, so this was a silent
    # no-op): mark the entry cancelled and fail its `abort` future; the
    # wait_any in _handle_task then cancels the in-flight branch (the
    # handler's future observes ->cancel) and the mark routes the task's
    # single completion to ack_cancel. An unknown or already-finished token is
    # a no-op (mirrors sdk-python _nexus.py, which debug-logs and moves on).
    method _handle_cancel_task ($cancel) {
        my $entry = $running{$cancel->task_token};
        return if !defined $entry || $entry->{cancelled};
        $entry->{cancelled} = 1;
        # Guard: if the branch settled first, wait_any already cancelled the
        # abort future; failing a settled future would croak.
        $entry->{abort}->fail('Nexus task cancelled by core', 'nexus_cancel_task')
            unless $entry->{abort}->is_ready;
        return;
    }

    # A server task (start or cancel operation). Decodes the poll response's
    # request, routes by variant, builds + sends the NexusTaskCompletion.
    async method _handle_task ($task) {
        my $poll        = $task->task;
        my $task_token  = $poll->task_token;
        my $request     = $poll->request;
        my $req_variant = $request->which_variant // '';

        # Register BEFORE running so a core cancel_task finds the task
        # (finding L20: the old empty entry carried no abort mechanism, so
        # cancel_task was a silent no-op and ack_cancel was dead code). This
        # is the single register site; the delete below is the single
        # deregister site, so completion, handler failure, and cancel all
        # pair through the same path and the map cannot leak.
        my $entry = $running{$task_token} = {
            abort     => Future->new,
            cancelled => 0,
        };

        my $completion;
        try {
            my $branch;
            if ($req_variant eq 'start_operation') {
                $branch = $self->_handle_start(
                    $task_token, $request, $task->endpoint);
            }
            elsif ($req_variant eq 'cancel_operation') {
                $branch = $self->_handle_cancel_operation(
                    $task_token, $request, $task->endpoint);
            }
            else {
                Temporalio::Exception::NexusHandler->throw(
                    message => "unrecognized Nexus request variant '$req_variant'",
                    type    => 'NOT_IMPLEMENTED',
                );
            }
            # Race the request branch against the abort future: when
            # _handle_cancel_task fails `abort`, wait_any cancels the pending
            # branch (Future::AsyncAwait propagates ->cancel down to the
            # handler's awaited future, so the handler observes cancellation)
            # and the failure lands in the catch below.
            $completion = await Future->wait_any($branch, $entry->{abort});
        }
        catch ($error) {
            if ($entry->{cancelled}) {
                # Aborted by a core cancel_task: the response content is
                # irrelevant, acknowledge the cancel (the ack_cancel variant
                # is for exactly this handler-aborted-by-cancellation case).
                $completion = $self->_completion($task_token, ack_cancel => 1);
            }
            else {
                $completion = await $self->_handler_error_completion(
                    $task_token, $error);
            }
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
                headers => ($request->can('header') ? ($request->header // {}) : {}),
                # B13 (#11): copy the inbound StartOperation async-completion
                # details so start_workflow can attach them to the backing
                # workflow start. The callback URL/header is what the server
                # calls on backing-workflow completion to resolve the caller's
                # parked operation; the request_id is the start idempotency key;
                # the links are the caller<->backing correlation (spec 26.2).
                callback        => $start->callback,
                callback_header => ($start->callback_header // {}),
                request_id      => $start->request_id,
                links           => [ map { { url => $_->url, type => $_->type } }
                                         @{ $start->links // [] } ])
            : Temporalio::Nexus::StartOperationContext->new(
                info => $info, client => $client, logger => $logger,
                headers => ($request->can('header') ? ($request->header // {}) : {}));

        # R73 (parity finding 3): fold the interceptor list over a
        # handler-running root and dispatch the start THROUGH the chain, the
        # Perl form of sdk-python's nexus middleware
        # (_interceptor.py:66-78,500-528 via _nexus.py:657-675). The input
        # carries the operation context in `ctx`; the operation input rides
        # the writable `args` field (Python's mutable `input`).
        my $inbound = Temporalio::Worker::Interceptor::build_nexus_operation_inbound(
            $interceptors, Temporalio::Worker::_RootNexusOperationInbound->new);
        my $start_input =
            Temporalio::Worker::Interceptor::Input::ExecuteNexusOperationStart->new(
                ctx  => $ctx,
                args => [$input],
                _root => sub ($in) {
                    # Invoke under the dynamically-scoped Nexus context, but
                    # end the `dynamically` scope BEFORE any await: a
                    # cancel_task abort (R32, finding L20) cancels this frame
                    # via the wait_any in _handle_task, and cancelling a frame
                    # suspended across a `dynamically` assignment segfaults
                    # perl 5.38.2 (Syntax::Keyword::Dynamically +
                    # Future::AsyncAwait cancel; verified empirically). The
                    # scope ends when this closure returns the (not-yet-
                    # awaited) future, so handler code up to its first await
                    # still sees the context.
                    dynamically $Temporalio::Nexus::CURRENT = $in->get('ctx');
                    return $self->_invoke(
                        $def->{code}, $in->get('ctx'), @{ $in->args });
                },
            );

        my $result;
        try {
            $result = await $self->_invoke(
                sub { $inbound->execute_nexus_operation_start($start_input) });
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
    # The cancel dispatches through the nexus-operation-inbound chain too
    # (spec R73, parity finding 3; sdk-python _interceptor.py:493-497,524-528):
    # the input carries a CancelOperationContext in `ctx` and the operation
    # token in `token`, and the chain root runs the real cancel work.
    async method _handle_cancel_operation ($task_token, $request, $endpoint) {
        my $cancel = $request->cancel_operation;
        my $token  = $cancel->operation_token;

        my $info = Temporalio::Nexus::OperationInfo->new(
            service    => $cancel->service,
            operation  => $cancel->operation,
            endpoint   => $endpoint,
            task_queue => $task_queue,
        );
        my $ctx = Temporalio::Nexus::CancelOperationContext->new(
            info => $info, client => $client, logger => $logger,
            operation_token => $token);

        my $inbound = Temporalio::Worker::Interceptor::build_nexus_operation_inbound(
            $interceptors, Temporalio::Worker::_RootNexusOperationInbound->new);
        my $cancel_input =
            Temporalio::Worker::Interceptor::Input::ExecuteNexusOperationCancel->new(
                ctx   => $ctx,
                token => $token,
                _root => sub ($in) {
                    return $self->_cancel_backing_workflow($in->get('token'));
                },
            );
        await $self->_invoke(
            sub { $inbound->execute_nexus_operation_cancel($cancel_input) });

        my $cancel_resp = $CancelOperationResponse->new({});
        return $self->_completion($task_token,
            completed => $Response->new({ cancel_operation => $cancel_resp }));
    }

    # The real cancel work behind the chain root: cancel the backing workflow
    # the operation token references (a no-op without a client or token).
    async method _cancel_backing_workflow ($token) {
        if (defined $client && defined $token && length $token) {
            my $wf = Temporalio::Nexus::WorkflowHandle->from_token($token);
            my $handle = $client->get_workflow_handle($wf->workflow_id);
            await $handle->cancel;
        }
        return;
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

A core C<cancel_task> aborts the matching in-flight task: the running
operation's future is cancelled (the handler observes the cancellation) and the
task's single completion is the C<ack_cancel> variant. An unknown or
already-finished task token is a no-op.

=head1 CONSTRUCTOR

=head2 new

    Temporalio::Worker::NexusDispatcher->new(
        registry => ..., data_converter => ..., task_queue => ...,
        completer => sub { ... }, client => ..., logger => ...,
        interceptors => [...]);

C<interceptors> is the combined worker interceptor list (client-supplied then
worker-supplied, outermost first). Each start/cancel folds it over a
handler-running root via
C<Temporalio::Worker::Interceptor::build_nexus_operation_inbound> and
dispatches through the resulting
L<Temporalio::Worker::NexusOperationInbound> chain (spec R73).

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
