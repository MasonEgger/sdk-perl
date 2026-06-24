# ABOUTME: Schedule backfill window (spec section 25): start_at (EXCLUSIVE) /
# ABOUTME: end_at (inclusive) / overlap, mapped to a BackfillRequest.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();
use Temporalio::Schedule::Policy ();

class Temporalio::Schedule::Backfill {
    field $start_at :param;            # epoch seconds — EXCLUSIVE
    field $end_at   :param;            # epoch seconds — inclusive
    field $overlap  :param = undef;

    method start_at { $start_at }
    method end_at   { $end_at }
    method overlap  { $overlap }

    method _to_proto {
        my $Req = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.BackfillRequest');
        return $Req->new({
            start_time     => _timestamp($start_at),
            end_time       => _timestamp($end_at),
            overlap_policy => Temporalio::Schedule::Policy::overlap_enum($overlap),
        });
    }

    sub _timestamp ($seconds) {
        my $Ts = Temporalio::Core::Proto::resolve('google.protobuf.Timestamp');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Ts->new({ seconds => $whole, nanos => $nanos });
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Backfill - a backfill time window for a schedule

=head1 SYNOPSIS

    my $bf = Temporalio::Schedule::Backfill->new(
        start_at => $t0, end_at => $t1, overlap => 'allow_all');

=head1 DESCRIPTION

A write-only backfill window (spec section 25), mapped to
C<temporal.api.schedule.v1.BackfillRequest>. C<start_at> is B<exclusive> and
C<end_at> is inclusive (both epoch seconds); C<overlap> is an optional
OverlapPolicy string overriding the schedule policy for this window.

=head1 CONSTRUCTOR

=head2 new

    my $bf = Temporalio::Schedule::Backfill->new(%fields);

Named parameters: C<start_at> (required, epoch seconds, exclusive), C<end_at>
(required, epoch seconds, inclusive), C<overlap> (optional).

=head1 METHODS

=head2 start_at

Accessor returning the exclusive backfill start (epoch seconds).

=head2 end_at

Accessor returning the inclusive backfill end (epoch seconds).

=head2 overlap

Accessor returning the per-window overlap policy override.

=cut
