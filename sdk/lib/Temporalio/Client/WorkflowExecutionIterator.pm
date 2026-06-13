# ABOUTME: Async iterator over ListWorkflowExecutions (spec section 7.4): pages
# ABOUTME: by next_page_token, yielding one WorkflowExecutionInfo per ->next
# ABOUTME: until pages and tokens are exhausted.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Core::Proto ();

class Temporalio::Client::_WorkflowExecutionIterator {
    field $client    :param;
    field $query     :param = undef;
    field $page_size :param = undef;

    field $current_page;
    field $current_index = 0;
    field $next_page_token;

    # next() — async; returns the next WorkflowExecutionInfo or undef when
    # exhausted. Mirrors sdk-python WorkflowExecutionAsyncIterator.__anext__
    # (client/_workflow.py 1631).
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
            return $current_page->[$current_index++];
        }
    }

    async method _fetch_next_page () {
        my $Request = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.ListWorkflowExecutionsRequest');
        my %fields = (
            namespace => $client->namespace,
            query     => $query // '',
        );
        $fields{page_size} = $page_size if defined $page_size && $page_size > 0;
        $fields{next_page_token} = $next_page_token
            if defined $next_page_token && length $next_page_token;

        my $response = await $client->_rpc_call(
            'ListWorkflowExecutions', $Request->new(\%fields));

        my $executions = $response->executions;
        $current_page  = (defined $executions && @$executions)
            ? [@$executions] : [];
        $current_index = 0;
        my $token = $response->next_page_token;
        $next_page_token = (defined $token && length $token) ? $token : undef;
        return;
    }
}

1;

__END__

=head1 NAME

Temporalio::Client::_WorkflowExecutionIterator - async list-workflows iterator

=head1 DESCRIPTION

An internal async iterator (spec section 7.4) returned by
C<< $client->list_workflows >>. It pages C<ListWorkflowExecutions> by
C<next_page_token>, yielding one C<WorkflowExecutionInfo> per
C<< await $iter->next >> until both the current page and the token are
exhausted, when C<next> returns C<undef>.

=cut
