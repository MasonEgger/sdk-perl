# ABOUTME: Handle to a started/identified workflow (spec section 7.6): result()
# ABOUTME: long-polls history and maps the terminal event, plus describe/cancel/
# ABOUTME: terminate/signal/query/fetch_history_events over the client RPC path.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Client::HistoryEventIterator ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Exception::Server ();
use Temporalio::Exception::Terminated ();
use Temporalio::Exception::Timeout ();
use Temporalio::Exception::WorkflowContinuedAsNew ();
use Temporalio::Exception::WorkflowFailure ();

class Temporalio::Client::WorkflowHandle {
    # temporal.api.enums.v1.HistoryEventFilterType (introspected from the
    # vendored proto): CLOSE_EVENT == 2. result() long-polls with this filter
    # so the server returns only the single terminal event (spec section 7.6).
    my $CLOSE_EVENT = 2;

    field $client                 :param;
    field $workflow_id            :param;
    field $run_id                 :param = undef;
    field $first_execution_run_id :param = undef;
    field $result_run_id          :param = undef;

    # Explicit readers (field :reader needs perl 5.40+; floor is 5.38).
    method client                 { $client }
    method workflow_id            { $workflow_id }
    method run_id                 { $run_id }
    method first_execution_run_id { $first_execution_run_id }
    method result_run_id          { $result_run_id }

    # result(follow_runs => 1, ...) — async (spec section 7.6, MUST match the
    # reference SDK terminal-event decision table — verified against sdk-python
    # client/_workflow.py WorkflowHandle.result lines 186-316). Long-polls
    # GetWorkflowExecutionHistory with the CLOSE_EVENT filter on the current
    # run id; the single returned event is the terminal event, mapped here.
    async method result (%opts) {
        my $follow_runs = exists $opts{follow_runs} ? $opts{follow_runs} : 1;

        # Base the result on result_run_id if present, else the handle run id
        # (sdk-python uses _result_run_id which falls back to the run id).
        my $hist_run_id = $result_run_id // $run_id;

        while (1) {
            my $followed_run_id;
            my $iter = $self->_history_iterator(
                $hist_run_id,
                wait_new_event    => 1,
                event_filter_type => $CLOSE_EVENT,
                skip_archival     => 1,
            );

            while (defined(my $event = await $iter->next)) {
                my $which = $event->which_attributes // '';

                if ($which eq 'workflow_execution_completed_event_attributes') {
                    my $attr = $event->workflow_execution_completed_event_attributes;
                    if ($follow_runs && length($attr->new_execution_run_id // '')) {
                        $followed_run_id = $attr->new_execution_run_id;
                        last;
                    }
                    return await $self->_decode_first_payload($attr->result);
                }
                elsif ($which eq 'workflow_execution_failed_event_attributes') {
                    my $attr = $event->workflow_execution_failed_event_attributes;
                    if ($follow_runs && length($attr->new_execution_run_id // '')) {
                        $followed_run_id = $attr->new_execution_run_id;
                        last;
                    }
                    my $cause =
                        await $client->data_converter->from_failure($attr->failure);
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution failed',
                        cause   => $cause,
                    );
                }
                elsif ($which eq 'workflow_execution_timed_out_event_attributes') {
                    my $attr = $event->workflow_execution_timed_out_event_attributes;
                    if ($follow_runs && length($attr->new_execution_run_id // '')) {
                        $followed_run_id = $attr->new_execution_run_id;
                        last;
                    }
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution timed out',
                        cause   => Temporalio::Exception::Timeout->new(
                            message => 'Workflow timed out'),
                    );
                }
                elsif ($which eq 'workflow_execution_canceled_event_attributes') {
                    my $attr = $event->workflow_execution_canceled_event_attributes;
                    my $details =
                        await $self->_decode_all_payloads($attr->details);
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution cancelled',
                        cause   => Temporalio::Exception::Cancelled->new(
                            message => 'Workflow cancelled',
                            details => $details,
                        ),
                    );
                }
                elsif ($which eq 'workflow_execution_terminated_event_attributes') {
                    my $attr   = $event->workflow_execution_terminated_event_attributes;
                    my $reason = $attr->reason;
                    Temporalio::Exception::WorkflowFailure->throw(
                        message => 'Workflow execution terminated',
                        cause   => Temporalio::Exception::Terminated->new(
                            message => (defined $reason && length $reason)
                                ? $reason : 'Workflow terminated',
                            reason  => $reason,
                        ),
                    );
                }
                elsif ($which eq 'workflow_execution_continued_as_new_event_attributes') {
                    my $attr = $event->workflow_execution_continued_as_new_event_attributes;
                    my $new_run = $attr->new_execution_run_id;
                    Temporalio::Exception::Server->throw(
                        message => 'Missing new run id on continue-as-new')
                        unless defined $new_run && length $new_run;
                    if ($follow_runs) {
                        $followed_run_id = $new_run;
                        last;
                    }
                    Temporalio::Exception::WorkflowContinuedAsNew->throw(
                        message    => 'Workflow continued as new',
                        new_run_id => $new_run,
                    );
                }
                # Any other event under a CLOSE_EVENT filter is unexpected; keep
                # draining the (single-event) page and loop again.
            }

            # We only reach here by `last` (a run we now follow) or by an empty
            # page. With a followed run id, loop on the new run; otherwise it is
            # an error — no terminal event was produced.
            if (defined $followed_run_id) {
                $hist_run_id = $followed_run_id;
                next;
            }
            Temporalio::Exception::Server->throw(
                message => 'No workflow completion event found');
        }
    }

    # describe(...) — async (spec section 7.6). Returns the decoded
    # DescribeWorkflowExecutionResponse, whose workflow_execution_info carries
    # the populated execution record. Verified against sdk-python _impl.py
    # describe_workflow (lines 361-384).
    async method describe (%opts) {
        my $request = _resolve(
            'temporal.api.workflowservice.v1.DescribeWorkflowExecutionRequest')
            ->new({
                namespace => $client->namespace,
                execution => $self->_execution_message,
            });
        return await $client->_rpc_call('DescribeWorkflowExecution', $request);
    }

    # cancel(...) — async (spec section 7.6 / sdk-python _impl.py
    # cancel_workflow 344-359). Issues RequestCancelWorkflowExecution against
    # the run, threading first_execution_run_id so the run chain is honored.
    async method cancel (%opts) {
        my $reason = $opts{reason};
        my %fields = (
            namespace          => $client->namespace,
            workflow_execution => $self->_execution_message,
            identity           => $client->identity,
            request_id         => Temporalio::Client::_new_uuid(),
            first_execution_run_id => $first_execution_run_id // '',
        );
        $fields{reason} = $reason if defined $reason && length $reason;
        my $request = _resolve(
            'temporal.api.workflowservice.v1.RequestCancelWorkflowExecutionRequest')
            ->new(\%fields);
        await $client->_rpc_call('RequestCancelWorkflowExecution', $request);
        return;
    }

    # terminate(reason => ..., details => [...], ...) — async (spec section 7.6
    # / sdk-python _impl.py terminate_workflow 506-534). Encodes details via the
    # data converter and threads first_execution_run_id.
    async method terminate (%opts) {
        my $reason  = $opts{reason};
        my $details = $opts{details} // [];
        my %fields = (
            namespace          => $client->namespace,
            workflow_execution => $self->_execution_message,
            identity           => $client->identity,
            first_execution_run_id => $first_execution_run_id // '',
        );
        $fields{reason} = $reason if defined $reason && length $reason;
        if (@$details) {
            $fields{details} = await $self->_encode_payloads($details);
        }
        my $request = _resolve(
            'temporal.api.workflowservice.v1.TerminateWorkflowExecutionRequest')
            ->new(\%fields);
        await $client->_rpc_call('TerminateWorkflowExecution', $request);
        return;
    }

    # signal($name, \@args, ...) — async (spec section 7.6 / sdk-python _impl.py
    # signal_workflow 474-504).
    async method signal ($name, $args = [], %opts) {
        Temporalio::Exception::Argument->throw(
            message => 'signal requires a signal name (string)')
            unless defined $name && !ref $name && length $name;
        my %fields = (
            namespace          => $client->namespace,
            workflow_execution => $self->_execution_message,
            signal_name        => $name,
            identity           => $client->identity,
            request_id         => Temporalio::Client::_new_uuid(),
        );
        if (@$args) {
            $fields{input} = await $self->_encode_payloads($args);
        }
        my $request = _resolve(
            'temporal.api.workflowservice.v1.SignalWorkflowExecutionRequest')
            ->new(\%fields);
        await $client->_rpc_call('SignalWorkflowExecution', $request);
        return;
    }

    # query($name, \@args, reject_condition => ..., ...) — async (spec section
    # 7.6 / sdk-python _impl.py query_workflow 411-472). Returns the decoded
    # single query result; a server-rejected query raises QueryRejected.
    async method query ($name, $args = [], %opts) {
        Temporalio::Exception::Argument->throw(
            message => 'query requires a query name (string)')
            unless defined $name && !ref $name && length $name;

        my $WorkflowQuery =
            _resolve('temporal.api.query.v1.WorkflowQuery');
        my %query_fields = (query_type => $name);
        if (@$args) {
            $query_fields{query_args} = await $self->_encode_payloads($args);
        }
        my %fields = (
            namespace => $client->namespace,
            execution => $self->_execution_message,
            query     => $WorkflowQuery->new(\%query_fields),
        );
        if (defined(my $rc = $opts{reject_condition})) {
            $fields{query_reject_condition} = $rc;
        }
        my $request = _resolve(
            'temporal.api.workflowservice.v1.QueryWorkflowRequest')
            ->new(\%fields);
        my $response =
            await $client->_rpc_call('QueryWorkflow', $request);

        if (defined(my $rejected = $response->query_rejected)) {
            require Temporalio::Exception::QueryRejected;
            Temporalio::Exception::QueryRejected->throw(
                message => 'Query rejected (workflow status '
                         . ($rejected->status // 0) . ')');
        }
        return await $self->_decode_first_payload($response->query_result);
    }

    # fetch_history_events(...) — returns an async iterator over the workflow's
    # history events (spec section 7.6 / sdk-python _workflow.py
    # fetch_history_events 417-456). Defaults to ALL_EVENT, no waiting.
    method fetch_history_events (%opts) {
        my $filter = $opts{event_filter_type};
        $filter = 1 unless defined $filter;    # ALL_EVENT
        return $self->_history_iterator(
            $run_id,
            page_size         => $opts{page_size},
            wait_new_event    => $opts{wait_new_event} ? 1 : 0,
            event_filter_type => $filter,
            skip_archival     => $opts{skip_archival} ? 1 : 0,
        );
    }

    # ----- private helpers -------------------------------------------------

    # An async page iterator over GetWorkflowExecutionHistory for one run id.
    method _history_iterator ($the_run_id, %opts) {
        return Temporalio::Client::_HistoryEventIterator->new(
            client            => $client,
            workflow_id       => $workflow_id,
            run_id            => $the_run_id,
            page_size         => $opts{page_size},
            wait_new_event    => $opts{wait_new_event} ? 1 : 0,
            event_filter_type => $opts{event_filter_type} // 1,
            skip_archival     => $opts{skip_archival} ? 1 : 0,
        );
    }

    method _execution_message () {
        return _resolve('temporal.api.common.v1.WorkflowExecution')->new({
            workflow_id => $workflow_id,
            run_id      => $run_id // '',
        });
    }

    async method _encode_payloads ($values) {
        my @payloads = await $client->data_converter->to_payloads($values);
        return _resolve('temporal.api.common.v1.Payloads')
            ->new({ payloads => [@payloads] });
    }

    async method _decode_first_payload ($payloads_msg) {
        my @values = await $self->_decode_all_payloads($payloads_msg);
        return undef unless @values;
        return $values[0];
    }

    async method _decode_all_payloads ($payloads_msg) {
        return () unless defined $payloads_msg;
        my $payloads = $payloads_msg->payloads;
        return () unless defined $payloads && @$payloads;
        return await $client->data_converter->from_payloads($payloads);
    }

    sub _resolve ($name) { Temporalio::Core::Proto::resolve($name) }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::WorkflowHandle - handle to a Temporal workflow execution

=head1 SYNOPSIS

    my $handle = await $client->start_workflow(
        'MyWorkflow', \@args, id => 'wf-1', task_queue => 'demo');

    my $value  = await $handle->result;            # blocks until terminal
    my $desc   = await $handle->describe;
    await $handle->signal('greet', ['hi']);
    await $handle->cancel(reason => 'no longer needed');
    await $handle->terminate(reason => 'kill it', details => ['why']);

    # Or, without an RPC:
    my $handle = $client->get_workflow_handle('wf-1', run_id => $rid);

=head1 DESCRIPTION

A reference to a single workflow execution (spec section 7.6), returned by
C<< $client->start_workflow >>, C<< ->signal_with_start_workflow >>, and
C<< ->get_workflow_handle >>. It carries the C<workflow_id>, the C<run_id>
(first run id from start, or the run id supplied to
C<get_workflow_handle>), C<first_execution_run_id>, and C<result_run_id>,
plus a back-reference to the owning L<Temporalio::Client>.

=head2 result

C<< await $handle->result >> long-polls C<GetWorkflowExecutionHistory> with
the C<CLOSE_EVENT> history-event filter and maps the single terminal event
to a value or exception, exactly per the Temporal spec (section 7.6,
verified against the reference SDK):

=over

=item * B<Completed> -> the decoded result payload value.

=item * B<Failed> -> L<Temporalio::Exception::WorkflowFailure> wrapping the
decoded failure as its C<cause>.

=item * B<TimedOut> -> C<WorkflowFailure> with cause
L<Temporalio::Exception::Timeout>.

=item * B<Canceled> -> C<WorkflowFailure> with cause
L<Temporalio::Exception::Cancelled>.

=item * B<Terminated> -> C<WorkflowFailure> with cause
L<Temporalio::Exception::Terminated> (the C<reason> preserved).

=item * B<ContinuedAsNew> -> with C<< follow_runs => 1 >> (the default) the
poll follows the new run; with C<< follow_runs => 0 >> it raises
L<Temporalio::Exception::WorkflowContinuedAsNew>.

=back

=head2 describe / cancel / terminate / signal / query / fetch_history_events

C<describe> returns the decoded C<DescribeWorkflowExecutionResponse>.
C<cancel> and C<terminate> issue their respective RPCs (threading
C<first_execution_run_id> through the run chain); C<terminate> encodes
C<details> through the data converter. C<signal> and C<query> send the named
signal/query with converter-encoded arguments; a server-rejected query
raises L<Temporalio::Exception::QueryRejected>. C<fetch_history_events>
returns an async iterator over the workflow's history events.

=head1 METHODS

=head2 client

Accessor returning the C<client> value.

=head2 first_execution_run_id

Accessor returning the C<first_execution_run_id> value.

=head2 result_run_id

Accessor returning the C<result_run_id> value.

=head2 run_id

Accessor returning the C<run_id> value.

=head2 workflow_id

Accessor returning the C<workflow_id> value.

=cut
