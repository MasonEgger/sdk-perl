# ABOUTME: Failure raised by create_schedule when a schedule with the same id
# ABOUTME: already exists (server ALREADY_EXISTS, re-mapped per spec section 25.3).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::ScheduleAlreadyRunning :isa(Temporalio::Exception) {
    field $schedule_id :param = undef;

    method schedule_id { $schedule_id }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Exception::ScheduleAlreadyRunning - schedule id already in use

=head1 DESCRIPTION

Raised by C<< $client->create_schedule >> when a schedule with the same id
already exists (spec section 25.3). The server returns C<ALREADY_EXISTS>;
C<create_schedule> catches the spec section 7.5 mapped error for
C<CreateSchedule> and re-raises this class. See L<Temporalio::Exception> for
the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $e = Temporalio::Exception::ScheduleAlreadyRunning->new(
        schedule_id => $id);

Named parameters: C<schedule_id> (optional).

=head1 METHODS

=head2 schedule_id

Accessor returning the conflicting schedule id.

=cut
