# ABOUTME: Schedule update value (spec section 25): the new schedule plus an
# ABOUTME: optional search-attributes replacement, returned by an update callback.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Schedule::Update {
    field $schedule          :param;
    field $search_attributes :param = undef;

    method schedule          { $schedule }
    method search_attributes { $search_attributes }
}

# The input handed to the updater callback by ScheduleHandle->update.
class Temporalio::Schedule::Update::Input {
    field $description :param;

    method description { $description }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Update - the result of a schedule update callback

=head1 SYNOPSIS

    my $update = Temporalio::Schedule::Update->new(schedule => $new_schedule);

=head1 DESCRIPTION

The value returned by the C<< $handle->update >> callback (spec section 25),
carrying the replacement L<Temporalio::Schedule::Schedule> and, optionally, a
search-attributes replacement. If C<search_attributes> is defined (even as an
empty set) the update clears and re-encodes the schedule's search attributes.

L<Temporalio::Schedule::Update::Input> is the value passed B<into> the updater
callback, exposing the current C<description>.

=head1 CONSTRUCTOR

=head2 new

    my $u = Temporalio::Schedule::Update->new(schedule => $s);

Named parameters: C<schedule> (required), C<search_attributes> (optional).

=head1 METHODS

=head2 schedule

Accessor returning the replacement schedule.

=head2 search_attributes

Accessor returning the search-attributes replacement (or undef to leave
unchanged).

=head2 description

(On L<Temporalio::Schedule::Update::Input>.) Accessor returning the current
schedule description handed to the updater callback.

=cut
