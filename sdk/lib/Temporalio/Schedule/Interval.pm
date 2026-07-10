# ABOUTME: Schedule interval spec (spec section 25): every/offset seconds mapped
# ABOUTME: to temporal.api.schedule.v1.IntervalSpec interval/phase Durations.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();

class Temporalio::Schedule::Interval {
    field $every  :param;            # seconds -> interval
    field $offset :param = undef;    # seconds -> phase

    method every  { $every }
    method offset { $offset }

    method _to_proto {
        my $Spec = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.IntervalSpec');
        my %f = (interval => _duration($every));
        $f{phase} = _duration($offset) if defined $offset;
        return $Spec->new(\%f);
    }

    # _from_proto($spec) — class method; phase only present when set.
    sub _from_proto ($class, $spec) {
        my $interval = $spec->interval;
        my $phase    = $spec->phase;
        return $class->new(
            every  => _duration_to_seconds($interval),
            offset => (defined $phase ? _duration_to_seconds($phase) : undef),
        );
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

Temporalio::Schedule::Interval - interval-based schedule match spec

=head1 SYNOPSIS

    my $iv = Temporalio::Schedule::Interval->new(every => 3600, offset => 1140);

=head1 DESCRIPTION

An interval match specification (spec section 25), mapped to
C<temporal.api.schedule.v1.IntervalSpec>. Matches times of the form
C<epoch + n * every + offset>. The Perl surface names them C<every>/C<offset>
(in seconds); the proto fields are C<interval>/C<phase> Durations.

=head1 CONSTRUCTOR

=head2 new

    my $iv = Temporalio::Schedule::Interval->new(every => $seconds);

Named parameters: C<every> (required, seconds), C<offset> (optional, seconds).

=head1 METHODS

=head2 every

Accessor returning the interval period in seconds.

=head2 offset

Accessor returning the interval offset in seconds (or undef).

=cut
