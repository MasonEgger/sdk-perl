# ABOUTME: Schedule policies (spec section 25): overlap/catchup_window/
# ABOUTME: pause_on_failure plus the OverlapPolicy string<->enum coercion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();

class Temporalio::Schedule::Policy {
    field $overlap          :param = 'skip';
    field $catchup_window   :param = 365 * 24 * 60 * 60;    # 365 days in seconds
    field $pause_on_failure :param = 0;

    method overlap          { $overlap }
    method catchup_window   { $catchup_window }
    method pause_on_failure { $pause_on_failure }

    method _to_proto {
        my $Pol = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.SchedulePolicies');
        return $Pol->new({
            overlap_policy   => overlap_enum($overlap),
            catchup_window   => _duration($catchup_window),
            pause_on_failure => $pause_on_failure ? 1 : 0,
        });
    }

    sub _from_proto ($class, $pol) {
        return $class->new(
            overlap          => overlap_name($pol->overlap_policy // 0),
            catchup_window   => _duration_to_seconds($pol->catchup_window),
            pause_on_failure => $pol->pause_on_failure ? 1 : 0,
        );
    }

    # ----- shared OverlapPolicy coercion (spec section 25) -----
    # MUST match temporal.api.enums.v1.ScheduleOverlapPolicy.
    my %OVERLAP = (
        unspecified     => 0,
        skip            => 1,
        buffer_one      => 2,
        buffer_all      => 3,
        cancel_other    => 4,
        terminate_other => 5,
        allow_all       => 6,
    );
    my %OVERLAP_REV = reverse %OVERLAP;

    sub overlap_enum ($value) {
        return 0 unless defined $value;
        return $value if $value =~ /\A[0-9]+\z/;
        my $num = $OVERLAP{$value};
        Temporalio::Exception::Argument->throw(
            message => "invalid overlap policy '$value' (expected one of "
                     . join(', ', sort keys %OVERLAP) . ')')
            unless defined $num;
        return $num;
    }

    sub overlap_name ($num) {
        return $OVERLAP_REV{$num // 0} // 'unspecified';
    }

    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve('google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
    }

    sub _duration_to_seconds ($duration) {
        return undef unless defined $duration;
        return ($duration->seconds // 0) + ($duration->nanos // 0) / 1_000_000_000;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Policy - overlap/catchup/pause policies of a schedule

=head1 SYNOPSIS

    my $pol = Temporalio::Schedule::Policy->new(overlap => 'buffer_one');

=head1 DESCRIPTION

Schedule policies (spec section 25), mapped to
C<temporal.api.schedule.v1.SchedulePolicies>. C<overlap> is an OverlapPolicy
string (C<unspecified>, C<skip>, C<buffer_one>, C<buffer_all>, C<cancel_other>,
C<terminate_other>, C<allow_all>) or the equivalent proto number;
C<catchup_window> is in seconds (default 365 days); C<pause_on_failure> is a
boolean.

This module also exports the shared OverlapPolicy coercion used by
L<Temporalio::Schedule::Backfill> and L<Temporalio::Client::ScheduleHandle>.

=head1 CONSTRUCTOR

=head2 new

    my $pol = Temporalio::Schedule::Policy->new(%fields);

Named parameters: C<overlap> (default C<'skip'>), C<catchup_window> (seconds,
default 365 days), C<pause_on_failure> (default 0).

=head1 METHODS

=head2 overlap

Accessor returning the overlap policy string.

=head2 catchup_window

Accessor returning the catchup window in seconds.

=head2 pause_on_failure

Accessor returning whether the schedule pauses on action failure.

=head1 FUNCTIONS

=head2 overlap_enum

    my $num = Temporalio::Schedule::Policy::overlap_enum('buffer_one');

Coerces an OverlapPolicy string (or proto number) to its proto enum value,
raising L<Temporalio::Exception::Argument> on an unknown name.

=head2 overlap_name

    my $name = Temporalio::Schedule::Policy::overlap_name(2);

Maps a proto enum value back to its OverlapPolicy string.

=cut
