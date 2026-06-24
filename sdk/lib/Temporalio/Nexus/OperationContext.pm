# ABOUTME: Nexus handler operation contexts (spec section 26.2): Start / Cancel /
# ABOUTME: WorkflowRun. WorkflowRunOperationContext::start_workflow returns a Nexus WorkflowHandle.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;

use Temporalio::Nexus::WorkflowHandle ();

# Shared info carried by every operation context (spec section 26.2). A plain
# value object: the service + operation being handled, plus the endpoint and
# task-queue the worker polled. Surfaced to handlers via the context and via
# the Temporalio::Nexus::info module helper.
class Temporalio::Nexus::OperationInfo {
    field $service    :param;
    field $operation  :param;
    field $endpoint   :param = undef;
    field $task_queue :param = undef;

    method service    { return $service }
    method operation  { return $operation }
    method endpoint   { return $endpoint }
    method task_queue { return $task_queue }
}

# StartOperationContext — passed as $ctx to a :SyncOperation handler. Carries
# the operation info, the worker's client, a logger, and the request headers.
class Temporalio::Nexus::StartOperationContext {
    field $info    :param;
    field $client  :param = undef;
    field $logger  :param = undef;
    field $headers :param = {};

    method info    { return $info }
    method client  { return $client }
    method logger  { return $logger }
    method headers { return $headers }
}

# CancelOperationContext — passed to the cancel path. Carries the info, client,
# logger, and the operation token to be cancelled.
class Temporalio::Nexus::CancelOperationContext {
    field $info            :param;
    field $client          :param = undef;
    field $logger          :param = undef;
    field $operation_token :param = undef;

    method info            { return $info }
    method client          { return $client }
    method logger          { return $logger }
    method operation_token { return $operation_token }
}

# WorkflowRunOperationContext — passed as $ctx to a :WorkflowRunOperation
# handler (spec section 26.2). Adds start_workflow: it starts the backing
# workflow through the worker's client and returns a
# Temporalio::Nexus::WorkflowHandle (NOT the client WorkflowHandle), whose token
# the dispatcher emits as the async operation token.
class Temporalio::Nexus::WorkflowRunOperationContext {
    field $info    :param;
    field $client  :param = undef;
    field $logger  :param = undef;
    field $headers :param = {};

    method info    { return $info }
    method client  { return $client }
    method logger  { return $logger }
    method headers { return $headers }

    # start_workflow($workflow, $args, %kwargs) -> (async) a
    # Temporalio::Nexus::WorkflowHandle. Mirrors sdk-python
    # WorkflowRunOperationContext.start_workflow: start via the client, then wrap
    # the namespace + workflow id into the Nexus handle the dispatcher tokenizes.
    async method start_workflow ($workflow, $args = [], %kwargs) {
        die "WorkflowRunOperationContext has no client to start the workflow\n"
            unless defined $client;
        my $handle = await $client->start_workflow($workflow, $args, %kwargs);
        return Temporalio::Nexus::WorkflowHandle->new(
            namespace   => $client->namespace,
            workflow_id => $handle->workflow_id,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Nexus::OperationContext - Nexus handler operation contexts

=head1 DESCRIPTION

The context objects passed to Nexus operation handlers (spec section 26.2):

=over 4

=item L<Temporalio::Nexus::StartOperationContext>

C<$ctx> for a C<:SyncOperation> handler. Accessors: C<info>, C<client>,
C<logger>, C<headers>.

=item L<Temporalio::Nexus::WorkflowRunOperationContext>

C<$ctx> for a C<:WorkflowRunOperation> handler. Adds
C<< start_workflow($workflow, $args, %kwargs) >> which starts the backing
workflow and returns a L<Temporalio::Nexus::WorkflowHandle>.

=item L<Temporalio::Nexus::CancelOperationContext>

C<$ctx> for the cancel path. Adds C<operation_token>.

=item L<Temporalio::Nexus::OperationInfo>

The shared C<service>/C<operation>/C<endpoint>/C<task_queue> info object.

=back

=head1 CONSTRUCTOR

=head2 new

Each context takes named parameters; see the per-class accessors. Constructed
by the Nexus dispatcher, not by author code.

=head1 METHODS

=head2 info

The L<Temporalio::Nexus::OperationInfo> for this operation.

=head2 client

The worker's client (or undef).

=head2 logger

The handler logger (or undef).

=head2 headers

The Nexus request headers hashref.

=head2 operation_token

(CancelOperationContext) the token of the operation being cancelled.

=head2 operation

(OperationInfo) the operation name.

=head2 service

(OperationInfo) the service name.

=head2 endpoint

(OperationInfo) the endpoint name.

=head2 task_queue

(OperationInfo) the worker task queue.

=head2 start_workflow

(WorkflowRunOperationContext) C<< start_workflow($workflow, $args, %kwargs) >>
starts the backing workflow and returns a L<Temporalio::Nexus::WorkflowHandle>.

=cut
