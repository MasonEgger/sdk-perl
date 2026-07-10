# ABOUTME: Decode-only lossy list view of a schedule (spec section 25), built
# ABOUTME: from a temporal.api.schedule.v1.ScheduleListEntry by list_schedules.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Schedule::ListDescription {
    field $id                :param;
    field $workflow_type     :param = undef;    # action workflow type name
    field $note              :param = undef;
    field $paused            :param = 0;
    field $recent_actions    :param = undef;     # epoch-seconds list
    field $next_action_times :param = undef;     # epoch-seconds list
    field $raw_entry         :param = undef;     # the ScheduleListEntry

    ADJUST {
        $recent_actions    //= [];
        $next_action_times //= [];
    }

    method id                { $id }
    method workflow_type     { $workflow_type }
    method note              { $note }
    method paused            { $paused }
    method recent_actions    { $recent_actions }
    method next_action_times { $next_action_times }
    method raw_entry         { $raw_entry }

    sub _from_proto ($class, $entry) {
        my $info   = $entry->info;
        my $note;
        my $paused = 0;
        my $wf_type;
        my (@recent, @future);
        if (defined $info) {
            my $n = $info->notes;
            $note   = (defined $n && length $n) ? $n : undef;
            $paused = $info->paused ? 1 : 0;
            my $wt = $info->workflow_type;
            $wf_type = $wt ? $wt->name : undef;
            for my $r (@{ $info->recent_actions // [] }) {
                push @recent, _ts_secs($r->actual_time);
            }
            for my $f (@{ $info->future_action_times // [] }) {
                push @future, _ts_secs($f);
            }
        }
        return $class->new(
            id                => $entry->schedule_id // '',
            workflow_type     => $wf_type,
            note              => $note,
            paused            => $paused,
            recent_actions    => \@recent,
            next_action_times => \@future,
            raw_entry         => $entry,
        );
    }

    sub _ts_secs ($ts) {
        return undef unless defined $ts;
        my $secs  = $ts->seconds // 0;
        my $nanos = $ts->nanos // 0;
        return undef if $secs == 0 && $nanos == 0;
        return $secs + $nanos / 1_000_000_000;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::ListDescription - a lossy list view of a schedule

=head1 DESCRIPTION

A decode-only, lossy list view of a schedule (spec section 25), built from a
C<temporal.api.schedule.v1.ScheduleListEntry> by C<< $client->list_schedules >>.
It carries the schedule id, the action's workflow type name, the note/paused
state, and recent/next action times (epoch seconds), plus the raw entry.

=head1 CONSTRUCTOR

=head2 new

    my $ld = Temporalio::Schedule::ListDescription->new(%fields);

Named parameters: C<id> (required), C<workflow_type>, C<note>, C<paused>,
C<recent_actions>, C<next_action_times>, C<raw_entry>.

=head1 METHODS

=head2 id

Accessor returning the schedule id.

=head2 workflow_type

Accessor returning the action's workflow type name.

=head2 note

Accessor returning the schedule note.

=head2 paused

Accessor returning whether the schedule is paused.

=head2 recent_actions

Accessor returning recent action times (epoch seconds).

=head2 next_action_times

Accessor returning upcoming action times (epoch seconds).

=head2 raw_entry

Accessor returning the raw C<ScheduleListEntry> proto.

=cut
