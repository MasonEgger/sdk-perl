# ABOUTME: Decode-only schedule info (spec section 25): action counts and the
# ABOUTME: recent/next action times from temporal.api.schedule.v1.ScheduleInfo.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Schedule::Info {
    field $num_actions               :param = 0;
    field $num_actions_missed_catchup_window :param = 0;
    field $num_actions_skipped_overlap :param = 0;
    field $running_actions           :param = undef;    # WorkflowExecution list
    field $recent_actions            :param = undef;    # epoch-seconds list
    field $next_action_times         :param = undef;    # epoch-seconds list
    field $created_at                :param = undef;
    field $last_updated_at           :param = undef;

    ADJUST {
        $running_actions   //= [];
        $recent_actions    //= [];
        $next_action_times //= [];
    }

    method num_actions                       { $num_actions }
    method num_actions_missed_catchup_window { $num_actions_missed_catchup_window }
    method num_actions_skipped_overlap       { $num_actions_skipped_overlap }
    method running_actions                   { $running_actions }
    method recent_actions                    { $recent_actions }
    method next_action_times                 { $next_action_times }
    method created_at                        { $created_at }
    method last_updated_at                   { $last_updated_at }

    sub _from_proto ($class, $info) {
        my $recent = $info->recent_actions // [];
        my $future = $info->future_action_times // [];
        return $class->new(
            num_actions => $info->action_count // 0,
            num_actions_missed_catchup_window =>
                $info->missed_catchup_window // 0,
            num_actions_skipped_overlap => $info->overlap_skipped // 0,
            running_actions => [ @{ $info->running_workflows // [] } ],
            recent_actions  => [
                map { _ts_secs($_->actual_time) } @$recent ],
            next_action_times => [ map { _ts_secs($_) } @$future ],
            created_at        => _ts_secs($info->create_time),
            last_updated_at   => _ts_secs($info->update_time),
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

Temporalio::Schedule::Info - read-only run-time info about a schedule

=head1 DESCRIPTION

Decode-only info about a schedule (spec section 25), built from
C<temporal.api.schedule.v1.ScheduleInfo> by C<_from_proto>. Action times are
exposed as epoch seconds.

=head1 CONSTRUCTOR

=head2 new

    my $i = Temporalio::Schedule::Info->new(%fields);

Named parameters: C<num_actions>, C<num_actions_missed_catchup_window>,
C<num_actions_skipped_overlap>, C<running_actions>, C<recent_actions>,
C<next_action_times>, C<created_at>, C<last_updated_at>.

=head1 METHODS

=head2 num_actions

Accessor returning the total action count.

=head2 num_actions_missed_catchup_window

Accessor returning the count of actions missed due to the catchup window.

=head2 num_actions_skipped_overlap

Accessor returning the count of actions skipped due to overlap.

=head2 running_actions

Accessor returning the currently-running workflow executions.

=head2 recent_actions

Accessor returning recent action times (epoch seconds).

=head2 next_action_times

Accessor returning upcoming action times (epoch seconds).

=head2 created_at

Accessor returning the schedule creation time (epoch seconds).

=head2 last_updated_at

Accessor returning the schedule last-update time (epoch seconds).

=cut
