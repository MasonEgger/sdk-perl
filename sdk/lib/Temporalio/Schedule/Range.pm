# ABOUTME: Schedule calendar Range (spec section 25): an inclusive/inclusive
# ABOUTME: integer range with a step, matching temporal.api.schedule.v1.Range.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();

class Temporalio::Schedule::Range {
    field $start :param;
    field $end   :param = undef;
    field $step  :param = 1;

    ADJUST {
        # A single value is start with end defaulting to start (proto treats
        # end < start as end == start, but we pass them verbatim).
        $end = $start unless defined $end;
    }

    method start { $start }
    method end   { $end }
    method step  { $step }

    # _to_proto — temporal.api.schedule.v1.Range; inclusive/inclusive, no +1.
    method _to_proto {
        my $Range = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.Range');
        return $Range->new({ start => $start, end => $end, step => $step });
    }

    # _from_proto($range) — class method; reads start/end/step verbatim.
    sub _from_proto ($class, $range) {
        return $class->new(
            start => $range->start // 0,
            end   => $range->end // 0,
            step  => $range->step || 1,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Range - inclusive integer range for schedule calendars

=head1 SYNOPSIS

    my $r = Temporalio::Schedule::Range->new(start => 0, end => 30, step => 5);

=head1 DESCRIPTION

A set of integer values used to match a field of a calendar time in a
L<Temporalio::Schedule::Calendar> (spec section 25). The range is inclusive on
both C<start> and C<end>, with an optional C<step> (default 1). Values are
passed to the proto verbatim (no off-by-one adjustment). A single value is
expressed as C<< start => N >> with C<end> defaulting to C<start>.

=head1 CONSTRUCTOR

=head2 new

    my $r = Temporalio::Schedule::Range->new(start => 1, end => 31);

Named parameters: C<start> (required), C<end> (default: C<start>), C<step>
(default 1).

=head1 METHODS

=head2 start

Accessor returning the inclusive range start.

=head2 end

Accessor returning the inclusive range end.

=head2 step

Accessor returning the range step.

=cut
