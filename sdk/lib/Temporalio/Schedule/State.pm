# ABOUTME: Schedule state (spec section 25): note/paused/limited+remaining
# ABOUTME: actions, mapped to temporal.api.schedule.v1.ScheduleState (note->notes).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();

class Temporalio::Schedule::State {
    field $note              :param = undef;    # -> notes
    field $paused            :param = 0;
    field $limited_actions   :param = 0;
    field $remaining_actions :param = 0;

    method note              { $note }
    method paused            { $paused }
    method limited_actions   { $limited_actions }
    method remaining_actions { $remaining_actions }

    method _to_proto {
        my $State = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.ScheduleState');
        return $State->new({
            notes             => $note // '',
            paused            => $paused ? 1 : 0,
            limited_actions   => $limited_actions ? 1 : 0,
            remaining_actions => $remaining_actions // 0,
        });
    }

    sub _from_proto ($class, $state) {
        my $notes = $state->notes;
        return $class->new(
            note              => (defined $notes && length $notes) ? $notes : undef,
            paused            => $state->paused ? 1 : 0,
            limited_actions   => $state->limited_actions ? 1 : 0,
            remaining_actions => $state->remaining_actions // 0,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::State - mutable state of a schedule

=head1 SYNOPSIS

    my $state = Temporalio::Schedule::State->new(paused => 1, note => 'hold');

=head1 DESCRIPTION

The state of a schedule (spec section 25), mapped to
C<temporal.api.schedule.v1.ScheduleState> with the C<note> to C<notes> remap.
On create, C<limited_actions> must be true exactly when C<remaining_actions> is
non-zero; that invariant is enforced by C<< $client->create_schedule >>, not
here.

=head1 CONSTRUCTOR

=head2 new

    my $state = Temporalio::Schedule::State->new(%fields);

Named parameters: C<note>, C<paused> (default 0), C<limited_actions>
(default 0), C<remaining_actions> (default 0).

=head1 METHODS

=head2 note

Accessor returning the human-readable note.

=head2 paused

Accessor returning whether the schedule is paused.

=head2 limited_actions

Accessor returning whether the action count is limited.

=head2 remaining_actions

Accessor returning the remaining action count.

=cut
