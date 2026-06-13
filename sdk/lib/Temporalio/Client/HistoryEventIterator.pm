# ABOUTME: Async iterator over a workflow's history events (spec section 7.6):
# ABOUTME: pages GetWorkflowExecutionHistory by next_page_token, yielding one
# ABOUTME: HistoryEvent per ->next until pages and tokens are exhausted.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Core::Proto ();

# Lives in the Temporalio::Client::_HistoryEventIterator package so the handle
# can construct it by the short internal name it uses.
class Temporalio::Client::_HistoryEventIterator {
    field $client            :param;
    field $workflow_id       :param;
    field $run_id            :param;
    field $page_size         :param = undef;
    field $wait_new_event    :param = 0;
    field $event_filter_type :param = 1;    # ALL_EVENT
    field $skip_archival     :param = 0;

    field $current_page;            # arrayref of HistoryEvent, or undef pre-fetch
    field $current_index = 0;
    field $next_page_token;
    field $fetched_once = 0;

    # next() — async; returns the next HistoryEvent or undef when exhausted.
    # Mirrors sdk-python WorkflowHistoryEventAsyncIterator.__anext__ (1821).
    async method next () {
        while (1) {
            if (!defined $current_page) {
                await $self->_fetch_next_page;
                next;
            }
            if ($current_index >= @$current_page) {
                if (defined $next_page_token && length $next_page_token) {
                    await $self->_fetch_next_page;
                    next;
                }
                return undef;
            }
            my $event = $current_page->[$current_index++];
            return $event;
        }
    }

    async method _fetch_next_page () {
        my $WfExec = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.WorkflowExecution');
        my $Request = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.GetWorkflowExecutionHistoryRequest');
        my %fields = (
            namespace                 => $client->namespace,
            execution                 => $WfExec->new({
                workflow_id => $workflow_id,
                run_id      => $run_id // '',
            }),
            wait_new_event            => $wait_new_event ? 1 : 0,
            history_event_filter_type => $event_filter_type,
            skip_archival             => $skip_archival ? 1 : 0,
        );
        $fields{maximum_page_size} = $page_size
            if defined $page_size && $page_size > 0;
        $fields{next_page_token} = $next_page_token
            if defined $next_page_token && length $next_page_token;

        my $response = await $client->_rpc_call(
            'GetWorkflowExecutionHistory', $Request->new(\%fields));

        my $history = $response->history;
        my $events  = defined $history ? $history->events : undef;
        $current_page    = (defined $events && @$events) ? [@$events] : [];
        $current_index   = 0;
        my $token = $response->next_page_token;
        $next_page_token = (defined $token && length $token) ? $token : undef;
        $fetched_once    = 1;
        return;
    }
}

1;

__END__

=head1 NAME

Temporalio::Client::_HistoryEventIterator - async history-event page iterator

=head1 DESCRIPTION

An internal async iterator (spec section 7.6) that pages
C<GetWorkflowExecutionHistory> by C<next_page_token>, yielding one
C<HistoryEvent> per C<< await $iter->next >> until both the current page and
the token are exhausted, when C<next> returns C<undef>. Used by
L<Temporalio::Client::WorkflowHandle> for both C<result> (with the
C<CLOSE_EVENT> filter and C<wait_new_event>) and C<fetch_history_events>.

=cut
