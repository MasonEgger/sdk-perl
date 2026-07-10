# ABOUTME: Schedule calendar spec (spec section 25): per-field Range lists with
# ABOUTME: load-bearing default ranges injected, mapped to StructuredCalendarSpec.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();
use Temporalio::Schedule::Range ();

class Temporalio::Schedule::Calendar {
    # Per-field default ranges (MUST-match sdk-python ScheduleCalendarSpec): an
    # empty field means "never match", so the constructor injects defaults.
    # year stays empty (empty year matches all years).
    field $second       :param = undef;
    field $minute       :param = undef;
    field $hour         :param = undef;
    field $day_of_month :param = undef;
    field $month        :param = undef;
    field $year         :param = undef;
    field $day_of_week  :param = undef;
    field $comment      :param = undef;

    ADJUST {
        $second       = [ Temporalio::Schedule::Range->new(start => 0) ]
            unless defined $second;
        $minute       = [ Temporalio::Schedule::Range->new(start => 0) ]
            unless defined $minute;
        $hour         = [ Temporalio::Schedule::Range->new(start => 0) ]
            unless defined $hour;
        $day_of_month = [ Temporalio::Schedule::Range->new(start => 1, end => 31) ]
            unless defined $day_of_month;
        $month        = [ Temporalio::Schedule::Range->new(start => 1, end => 12) ]
            unless defined $month;
        $year         = [] unless defined $year;
        $day_of_week  = [ Temporalio::Schedule::Range->new(start => 0, end => 6) ]
            unless defined $day_of_week;
    }

    method second       { $second }
    method minute       { $minute }
    method hour         { $hour }
    method day_of_month { $day_of_month }
    method month        { $month }
    method year         { $year }
    method day_of_week  { $day_of_week }
    method comment      { $comment }

    method _to_proto {
        my $Spec = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.StructuredCalendarSpec');
        return $Spec->new({
            second       => [ map { $_->_to_proto } @$second ],
            minute       => [ map { $_->_to_proto } @$minute ],
            hour         => [ map { $_->_to_proto } @$hour ],
            day_of_month => [ map { $_->_to_proto } @$day_of_month ],
            month        => [ map { $_->_to_proto } @$month ],
            year         => [ map { $_->_to_proto } @$year ],
            day_of_week  => [ map { $_->_to_proto } @$day_of_week ],
            comment      => $comment // '',
        });
    }

    # _from_proto($spec) — class method; decode a StructuredCalendarSpec. The
    # server has already populated every field, so no defaults are injected.
    sub _from_proto ($class, $spec) {
        my $ranges = sub ($list) {
            [ map { Temporalio::Schedule::Range->_from_proto($_) }
                @{ $list // [] } ];
        };
        my $comment = $spec->comment;
        return $class->new(
            second       => $ranges->($spec->second),
            minute       => $ranges->($spec->minute),
            hour         => $ranges->($spec->hour),
            day_of_month => $ranges->($spec->day_of_month),
            month        => $ranges->($spec->month),
            year         => $ranges->($spec->year),
            day_of_week  => $ranges->($spec->day_of_week),
            comment      => (defined $comment && length $comment) ? $comment : undef,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Calendar - calendar-based schedule match spec

=head1 SYNOPSIS

    my $cal = Temporalio::Schedule::Calendar->new(
        hour => [ Temporalio::Schedule::Range->new(start => 9) ],
    );

=head1 DESCRIPTION

A calendar match specification (spec section 25), mapped to
C<temporal.api.schedule.v1.StructuredCalendarSpec>. Each field is a list of
L<Temporalio::Schedule::Range>. Per-field default ranges are load-bearing: an
empty field means "never match", so the constructor injects the same defaults
as the reference SDKs (C<second>/C<minute>/C<hour> default to C<[0]>,
C<day_of_month> to C<1..31>, C<month> to C<1..12>, C<day_of_week> to C<0..6>;
C<year> stays empty, which matches all years).

=head1 CONSTRUCTOR

=head2 new

    my $cal = Temporalio::Schedule::Calendar->new(%fields);

Named parameters (each a Range arrayref): C<second>, C<minute>, C<hour>,
C<day_of_month>, C<month>, C<year>, C<day_of_week>, plus C<comment>.

=head1 METHODS

=head2 second

Accessor returning the C<second> Range list.

=head2 minute

Accessor returning the C<minute> Range list.

=head2 hour

Accessor returning the C<hour> Range list.

=head2 day_of_month

Accessor returning the C<day_of_month> Range list.

=head2 month

Accessor returning the C<month> Range list.

=head2 year

Accessor returning the C<year> Range list.

=head2 day_of_week

Accessor returning the C<day_of_week> Range list.

=head2 comment

Accessor returning the free-form comment.

=cut
