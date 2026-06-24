# ABOUTME: Async iterator over ListSchedules (spec section 25): pages by
# ABOUTME: next_page_token, yielding one Schedule::ListDescription per ->next.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Core::Proto ();
use Temporalio::Schedule::ListDescription ();

class Temporalio::Client::_ScheduleListIterator {
    field $client    :param;
    field $query     :param = undef;
    field $page_size :param = undef;

    field $current_page;
    field $current_index = 0;
    field $next_page_token;

    # next() — async; returns the next Schedule::ListDescription or undef when
    # exhausted. Mirrors the WorkflowExecutionIterator template.
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
            'temporal.api.workflowservice.v1.ListSchedulesRequest');
        my %fields = (
            namespace => $client->namespace,
            query     => $query // '',
        );
        $fields{maximum_page_size} = $page_size
            if defined $page_size && $page_size > 0;
        $fields{next_page_token} = $next_page_token
            if defined $next_page_token && length $next_page_token;

        my $response =
            await $client->_rpc_call('ListSchedules', $Request->new(\%fields));

        my $schedules = $response->schedules;
        $current_page = (defined $schedules && @$schedules)
            ? [ map { Temporalio::Schedule::ListDescription->_from_proto($_) }
                @$schedules ]
            : [];
        $current_index = 0;
        my $token = $response->next_page_token;
        $next_page_token = (defined $token && length $token) ? $token : undef;
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::_ScheduleListIterator - async list-schedules iterator

=head1 DESCRIPTION

An internal async iterator (spec section 25) returned by
C<< $client->list_schedules >>. It pages C<ListSchedules> by
C<next_page_token>, yielding one L<Temporalio::Schedule::ListDescription> per
C<< await $iter->next >> until both the current page and the token are
exhausted, when C<next> returns C<undef>. No RPC is made until the first
C<next> is awaited.

=cut
