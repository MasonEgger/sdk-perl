# ABOUTME: Schedule spec (spec section 25): calendars/intervals/cron/skip plus
# ABOUTME: start/end/jitter/time-zone, with the load-bearing proto field remaps.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();
use Temporalio::Schedule::Calendar ();
use Temporalio::Schedule::Interval ();

class Temporalio::Schedule::Spec {
    field $calendars        :param = undef;    # -> structured_calendar
    field $intervals        :param = undef;    # -> interval
    field $cron_expressions :param = undef;    # -> cron_string
    field $skip             :param = undef;    # -> exclude_structured_calendar
    field $start_at         :param = undef;    # epoch seconds -> start_time
    field $end_at           :param = undef;    # epoch seconds -> end_time
    field $jitter           :param = undef;    # seconds -> jitter Duration
    field $time_zone_name   :param = undef;    # -> timezone_name

    ADJUST {
        $calendars        //= [];
        $intervals        //= [];
        $cron_expressions //= [];
        $skip             //= [];
    }

    method calendars        { $calendars }
    method intervals        { $intervals }
    method cron_expressions { $cron_expressions }
    method skip             { $skip }
    method start_at         { $start_at }
    method end_at           { $end_at }
    method jitter           { $jitter }
    method time_zone_name   { $time_zone_name }

    method _to_proto {
        my $Spec = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.ScheduleSpec');
        my %f = (
            structured_calendar         => [ map { $_->_to_proto } @$calendars ],
            cron_string                 => [ @$cron_expressions ],
            interval                    => [ map { $_->_to_proto } @$intervals ],
            exclude_structured_calendar => [ map { $_->_to_proto } @$skip ],
            timezone_name               => $time_zone_name // '',
        );
        $f{start_time} = _timestamp($start_at) if defined $start_at;
        $f{end_time}   = _timestamp($end_at)   if defined $end_at;
        $f{jitter}     = _duration($jitter)    if defined $jitter;
        return $Spec->new(\%f);
    }

    # _from_proto($spec) — class method. The server returns only
    # structured_calendar/interval (cron compiles server-side), so
    # cron_expressions is left empty on decode.
    sub _from_proto ($class, $spec) {
        my $sc = $spec->structured_calendar // [];
        my $iv = $spec->interval // [];
        my $ex = $spec->exclude_structured_calendar // [];
        my $tz = $spec->timezone_name;
        return $class->new(
            calendars => [
                map { Temporalio::Schedule::Calendar->_from_proto($_) } @$sc ],
            intervals => [
                map { Temporalio::Schedule::Interval->_from_proto($_) } @$iv ],
            cron_expressions => [],
            skip => [
                map { Temporalio::Schedule::Calendar->_from_proto($_) } @$ex ],
            start_at => _timestamp_to_seconds($spec->start_time),
            end_at   => _timestamp_to_seconds($spec->end_time),
            jitter   => _duration_to_seconds($spec->jitter),
            time_zone_name => (defined $tz && length $tz) ? $tz : undef,
        );
    }

    sub _timestamp ($seconds) {
        my $Ts = Temporalio::Core::Proto::resolve('google.protobuf.Timestamp');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Ts->new({ seconds => $whole, nanos => $nanos });
    }

    sub _timestamp_to_seconds ($ts) {
        return undef unless defined $ts;
        my $secs  = $ts->seconds // 0;
        my $nanos = $ts->nanos // 0;
        return undef if $secs == 0 && $nanos == 0;    # unset timestamp
        return $secs + $nanos / 1_000_000_000;
    }

    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve('google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
    }

    sub _duration_to_seconds ($duration) {
        return undef unless defined $duration;
        my $secs  = $duration->seconds // 0;
        my $nanos = $duration->nanos // 0;
        return undef if $secs == 0 && $nanos == 0;
        return $secs + $nanos / 1_000_000_000;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Spec - when a schedule's action should run

=head1 SYNOPSIS

    my $spec = Temporalio::Schedule::Spec->new(
        intervals => [ Temporalio::Schedule::Interval->new(every => 3600) ],
    );

=head1 DESCRIPTION

A schedule spec (spec section 25), mapped to
C<temporal.api.schedule.v1.ScheduleSpec> with load-bearing field remaps:
C<calendars> to C<structured_calendar>, C<cron_expressions> to C<cron_string>,
C<intervals> to C<interval>, C<skip> to C<exclude_structured_calendar>, and
C<time_zone_name> to C<timezone_name>. C<start_at>/C<end_at> are epoch seconds
mapped to C<start_time>/C<end_time> Timestamps (the interval start_time is
inclusive); C<jitter> is seconds mapped to the C<jitter> Duration.

On C<_from_proto> the server returns only structured/interval forms (cron
compiles server-side), so C<cron_expressions> is left empty.

=head1 CONSTRUCTOR

=head2 new

    my $spec = Temporalio::Schedule::Spec->new(%fields);

Named parameters: C<calendars>, C<intervals>, C<cron_expressions>, C<skip>
(arrayrefs), C<start_at>, C<end_at> (epoch seconds), C<jitter> (seconds),
C<time_zone_name>.

=head1 METHODS

=head2 calendars

Accessor returning the calendar specs.

=head2 intervals

Accessor returning the interval specs.

=head2 cron_expressions

Accessor returning the cron expression strings.

=head2 skip

Accessor returning the skip calendar specs.

=head2 start_at

Accessor returning the inclusive start time (epoch seconds).

=head2 end_at

Accessor returning the inclusive end time (epoch seconds).

=head2 jitter

Accessor returning the jitter in seconds.

=head2 time_zone_name

Accessor returning the IANA time zone name.

=cut
