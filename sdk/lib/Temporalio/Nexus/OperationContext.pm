# ABOUTME: Nexus handler operation contexts (spec section 26.2): Start / Cancel /
# ABOUTME: WorkflowRun. WorkflowRunOperationContext::start_workflow returns a Nexus WorkflowHandle.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;

use Temporalio::Nexus::WorkflowHandle ();
use Temporalio::Nexus::Link ();
use Temporalio::Core::Proto ();

# Shared info carried by every operation context (spec section 26.2). A plain
# value object: the service + operation being handled, plus the endpoint and
# task-queue the worker polled. Surfaced to handlers via the context and via
# the Temporalio::Nexus::info module helper.
class Temporalio::Nexus::OperationInfo {
    field $service    :param;
    field $operation  :param;
    field $endpoint   :param = undef;
    field $task_queue :param = undef;

    # The namespace of the worker handling this operation (spec R89, nexus
    # finding 4; Python parity: Info.namespace,
    # nexus/_operation_context.py:85). Dispatcher-injected from the worker's
    # client namespace (worker/_nexus.py:258-266,398-405).
    field $namespace  :param = undef;

    method service    { return $service }
    method operation  { return $operation }
    method endpoint   { return $endpoint }
    method task_queue { return $task_queue }
    method namespace  { return $namespace }
}

# StartOperationContext — passed as $ctx to a :SyncOperation handler. Carries
# the operation info, the worker's client, a logger, and the request headers.
class Temporalio::Nexus::StartOperationContext {
    field $info    :param;
    field $client  :param = undef;
    field $logger  :param = undef;
    field $headers :param = {};

    # The worker runtime's metric meter (spec R83), dispatcher-injected; the
    # shared _context_meter helper below wraps it with the Nexus attribute
    # set lazily (Python parity: nexus/_operation_context.py:107,201-209).
    field $metric_meter :param = undef;
    field $context_metric_meter;

    # The dispatcher-shared worker-shutdown Temporalio::Common::Event (spec
    # R89, nexus finding 4; the same mechanism as the activity dispatcher's
    # R84 event), set once at worker shutdown-begin. Backs
    # Temporalio::Nexus::is_worker_shutdown / wait_for_worker_shutdown(_sync).
    # Python parity: _worker_shutdown_event injected per context
    # (worker/_nexus.py:258-266,398-405). undef (a manual construction) means
    # shutdown is not observable through this context.
    field $worker_shutdown_event :param = undef;

    method info    { return $info }
    method client  { return $client }
    method logger  { return $logger }
    method headers { return $headers }
    method worker_shutdown_event { return $worker_shutdown_event }

    method metric_meter {
        return $context_metric_meter //=
            Temporalio::Nexus::OperationContext::_context_meter(
                $metric_meter, $info);
    }
}

# CancelOperationContext — passed to the cancel path. Carries the info, client,
# logger, and the operation token to be cancelled.
class Temporalio::Nexus::CancelOperationContext {
    field $info            :param;
    field $client          :param = undef;
    field $logger          :param = undef;
    field $operation_token :param = undef;

    # The worker runtime's metric meter (spec R83); see StartOperationContext.
    field $metric_meter :param = undef;
    field $context_metric_meter;

    # The worker-shutdown event (spec R89); see StartOperationContext.
    field $worker_shutdown_event :param = undef;

    method info            { return $info }
    method client          { return $client }
    method logger          { return $logger }
    method operation_token { return $operation_token }
    method worker_shutdown_event { return $worker_shutdown_event }

    method metric_meter {
        return $context_metric_meter //=
            Temporalio::Nexus::OperationContext::_context_meter(
                $metric_meter, $info);
    }
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

    # Inbound StartOperation details the dispatcher copies off the request (B13
    # #11): the caller's async-completion callback URL + header, the Nexus
    # request_id (an idempotency key), and the caller's links. start_workflow
    # threads these onto the backing-workflow start so the server notifies the
    # caller on completion (spec section 26.2).
    field $callback        :param = undef;
    field $callback_header :param = {};
    field $request_id      :param = undef;
    field $links           :param = [];

    # The worker runtime's metric meter (spec R83); see StartOperationContext.
    field $metric_meter :param = undef;
    field $context_metric_meter;

    # The worker-shutdown event (spec R89); see StartOperationContext.
    field $worker_shutdown_event :param = undef;

    method info            { return $info }
    method client          { return $client }
    method logger          { return $logger }
    method headers         { return $headers }
    method callback        { return $callback }
    method callback_header { return $callback_header }
    method request_id      { return $request_id }
    method links           { return $links }
    method worker_shutdown_event { return $worker_shutdown_event }

    method metric_meter {
        return $context_metric_meter //=
            Temporalio::Nexus::OperationContext::_context_meter(
                $metric_meter, $info);
    }

    # start_workflow($workflow, $args, %kwargs) -> (async) a
    # Temporalio::Nexus::WorkflowHandle. Mirrors sdk-python
    # WorkflowRunOperationContext.start_workflow: start via the client, then wrap
    # the namespace + workflow id into the Nexus handle the dispatcher tokenizes.
    #
    # B13 (#11): a :WorkflowRunOperation backing-workflow start MUST carry the
    # Nexus async-completion callback so the server delivers this workflow's
    # result to the caller's parked operation on completion. Before this, the
    # start issued a plain start_workflow with completionCallbacks:null, so the
    # backing workflow reached WorkflowExecutionCompleted while the caller's
    # operation parked forever (server: `Pending Nexus Operations: 1`). The
    # callback/links/request_id wiring lives HERE, the one place a workflow-run
    # operation starts its backing workflow.
    async method start_workflow ($workflow, $args = [], %kwargs) {
        die "WorkflowRunOperationContext has no client to start the workflow\n"
            unless defined $client;

        # Convert the caller's inbound links to temporal links (best-effort: an
        # unparseable link is dropped, never breaking the start), then build the
        # Nexus completion callback carrying those links (spec section 26.2,
        # MUST-match sdk-python _get_callbacks/_get_links).
        my @temporal_links =
            grep { defined }
            map { Temporalio::Nexus::Link::nexus_link_to_temporal_link(
                    $_->{url}, $_->{type}) }
            @{ $links // [] };

        my @callbacks = _nexus_completion_callbacks(
            $callback, $callback_header, \@temporal_links);

        my $handle = await $client->start_workflow($workflow, $args,
            %kwargs,
            (@callbacks       ? (completion_callbacks => \@callbacks)      : ()),
            (@temporal_links  ? (links                => \@temporal_links) : ()),
            (defined $request_id && length $request_id
                              ? (request_id           => $request_id)      : ()),
        );
        return Temporalio::Nexus::WorkflowHandle->new(
            namespace   => $client->namespace,
            workflow_id => $handle->workflow_id,
        );
    }

    # Build the temporal.api.common.v1.Callback list for the backing-workflow
    # start. Empty when there is no callback URL (a manual/test invocation
    # without an inbound Nexus request): the start then behaves like any other.
    sub _nexus_completion_callbacks ($url, $header, $temporal_links) {
        return () unless defined $url && length $url;
        my $Callback = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.Callback');
        my $Nexus = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.Callback.Nexus');
        return ($Callback->new({
            nexus => $Nexus->new({ url => $url, header => ($header // {}) }),
            links => $temporal_links,
        }));
    }
}

# The shared context-meter builder behind the three contexts' metric_meter
# accessors (spec R83): wraps the dispatcher-injected runtime meter with the
# Nexus attribute set, MUST-matching sdk-python's _TemporalOperationCtx
# .metric_meter attributes (nexus/_operation_context.py:201-209). Raises when
# the context was constructed without a meter. Fully qualified: this file has
# no ambient package, so a bare `sub` here would land in main::. Classic @_
# unpacking, NOT a signature: a signatured named sub compiled at the end of
# this file poisons the next attribute-bearing declaration a later `require`
# compiles (the perl 5.38.2 parser-state bug in lessons.md — it broke
# Runtime/MetricMeter.pm's `field :param` lines when this file loaded first).
sub Temporalio::Nexus::OperationContext::_context_meter {
    my ($meter, $info) = @_;
    if (!defined $meter) {
        require Temporalio::Exception::Runtime;
        Temporalio::Exception::Runtime->throw(
            message => 'no metric meter is available on this Nexus operation'
                     . ' context (constructed without one)');
    }
    return $meter->with_additional_attributes({
        nexus_service   => $info->service,
        nexus_operation => $info->operation,
        (defined $info->task_queue
            ? (task_queue => $info->task_queue) : ()),
    });
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

=head2 metric_meter

(all three contexts) The operation's metric meter (spec R83): a
L<Temporalio::Runtime::MetricMeter::Meter> backed by the worker runtime's
configured exporter, carrying the C<nexus_service>, C<nexus_operation>, and
C<task_queue> attributes (Python parity:
C<nexus/_operation_context.py:107>). Raises L<Temporalio::Exception::Runtime>
when the context was constructed without a meter.

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

=head2 namespace

(OperationInfo) the namespace of the worker handling this operation (spec
R89; Python parity: C<Info.namespace>). C<undef> when constructed without one.

=head2 worker_shutdown_event

(all three contexts) the dispatcher-shared worker-shutdown
L<Temporalio::Common::Event> (spec R89), set once at worker shutdown-begin.
Backs C<Temporalio::Nexus::is_worker_shutdown> and the
C<wait_for_worker_shutdown> waiters. C<undef> (a manual construction outside a
worker) means shutdown is not observable through this context.

=head2 start_workflow

(WorkflowRunOperationContext) C<< start_workflow($workflow, $args, %kwargs) >>
starts the backing workflow and returns a L<Temporalio::Nexus::WorkflowHandle>.

=cut
