# ABOUTME: Handle to a schedule (spec section 25): id/client readers. The
# ABOUTME: schedule operations (describe/update/etc.) land in plan step P8.2.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Client::ScheduleHandle {
    field $client :param;
    field $id     :param;

    # Explicit readers (field :reader needs perl 5.40+; floor is 5.38).
    method client { $client }
    method id     { $id }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::ScheduleHandle - handle to a Temporal schedule

=head1 SYNOPSIS

    my $h = $client->get_schedule_handle('my-schedule');
    my $id = $h->id;

=head1 DESCRIPTION

A handle to a schedule (spec section 25), mirroring
L<Temporalio::Client::WorkflowHandle>. Returned by
C<< $client->get_schedule_handle >> (no RPC) and
C<< $client->create_schedule >>. It exposes the C<id> and owning C<client>.
The schedule operations (describe, update, delete, backfill, trigger,
pause, unpause) arrive in a later plan step.

=head1 CONSTRUCTOR

=head2 new

    my $h = Temporalio::Client::ScheduleHandle->new(client => $c, id => $id);

Named parameters: C<client> (required), C<id> (required).

=head1 METHODS

=head2 client

Accessor returning the owning client.

=head2 id

Accessor returning the schedule id.

=cut
