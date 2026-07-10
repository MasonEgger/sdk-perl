# ABOUTME: Immutable per-activity cancellation details (spec R76): why the
# ABOUTME: activity was cancelled — reason name + the six boolean causes from
# ABOUTME: the Cancel job's ActivityCancellationDetails proto. Python parity
# ABOUTME: activity.py:169-191 (frozen ActivityCancellationDetails dataclass).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

# ActivityCancelReason number -> name, from the vendored proto enum
# (sdk/share/proto/temporal/sdk/core/activity_task/activity_task.proto:87-100).
# Enum fields decode as plain numbers in this SDK (the pure-Perl Protobuf
# convention, cf. Runner.pm cancellation_type); the map turns the number into
# the wire name so bodies can match on 'WORKER_SHUTDOWN' instead of 3.
my %REASON_NAME = (
    0 => 'NOT_FOUND',
    1 => 'CANCELLED',
    2 => 'TIMED_OUT',
    3 => 'WORKER_SHUTDOWN',
    4 => 'PAUSED',
    5 => 'RESET',
);

class Temporalio::Activity::CancellationDetails {
    # The Cancel job's primary ActivityCancelReason as its enum NAME (e.g.
    # 'WORKER_SHUTDOWN'), or the raw number for a value newer than the pinned
    # proto. Exposing the reason is a deliberate Perl addition over Python,
    # which logs cancel.reason and then drops it (worker/_activity.py:220);
    # spec R76 requires the context to report "the matching reason and
    # details", so it rides here alongside the booleans.
    field $reason :param = undef;

    # The six boolean causes, named per Python's frozen dataclass fields
    # (activity.py:169-191). Note cancel_requested maps from the proto's
    # is_cancelled, mirroring _from_proto at activity.py:180-191.
    field $not_found        :param = 0;
    field $cancel_requested :param = 0;
    field $paused           :param = 0;
    field $reset            :param = 0;
    field $timed_out        :param = 0;
    field $worker_shutdown  :param = 0;

    method reason           { $reason }
    method not_found        { $not_found }
    method cancel_requested { $cancel_requested }
    method paused           { $paused }
    method reset            { $reset }
    method timed_out        { $timed_out }
    method worker_shutdown  { $worker_shutdown }

    # from_proto($reason_number, $details_proto_or_undef) -> a new instance.
    # The Perl form of Python's ActivityCancellationDetails._from_proto
    # (activity.py:180-191), plus the captured reason (see the field comment).
    # $details may be undef (an absent sub-message decodes to undef here,
    # unlike proto3 Python's auto-vivified default message): all booleans stay
    # false. A plain sub, not a method, so it lives INSIDE the class block —
    # the block form of `class` restores the ambient package after the closing
    # brace, and this file declares no other package (the _as_exception
    # precedent in ActivityDispatcher.pm). Placed last: on perl 5.38.2 a
    # signatured named sub makes a following `field $x :param;` fail to parse.
    sub from_proto ($reason, $details) {
        my $n = $reason // 0;
        return Temporalio::Activity::CancellationDetails->new(
            reason           => $REASON_NAME{$n} // $n,
            not_found        => ($details && $details->is_not_found)       ? 1 : 0,
            cancel_requested => ($details && $details->is_cancelled)       ? 1 : 0,
            paused           => ($details && $details->is_paused)          ? 1 : 0,
            timed_out        => ($details && $details->is_timed_out)       ? 1 : 0,
            worker_shutdown  => ($details && $details->is_worker_shutdown) ? 1 : 0,
            reset            => ($details && $details->is_reset)           ? 1 : 0,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Activity::CancellationDetails - why an activity was cancelled

=head1 SYNOPSIS

    use Temporalio::Activity;

    # Inside an activity body, after its cancellation fired:
    my $details = Temporalio::Activity::context()->cancellation_details;
    if ($details && $details->worker_shutdown) { ... }
    if ($details && $details->paused)          { ... }

=head1 DESCRIPTION

An immutable value object carrying the cause of an activity cancellation
(spec R76). When sdk-core delivers a C<Cancel> activity task, the dispatcher
captures the task's C<reason> (an C<ActivityCancelReason>) and its
C<ActivityCancellationDetails> sub-message into one of these and exposes it
through L<Temporalio::Activity::Context/cancellation_details>, so a body can
distinguish an explicit server cancel from a worker shutdown, pause, reset,
timeout, or not-found. Mirrors sdk-python's frozen
C<ActivityCancellationDetails> dataclass (C<activity.py:169-191>); the
C<reason> accessor is a Perl addition (Python logs the reason and drops it).

Details are set once when the cancel arrives and do not change.

=head1 METHODS

=head2 reason

The primary C<ActivityCancelReason> as its enum name: C<NOT_FOUND>,
C<CANCELLED>, C<TIMED_OUT>, C<WORKER_SHUTDOWN>, C<PAUSED>, or C<RESET> (the
raw number for a reason newer than the pinned proto).

=head2 cancel_requested

True when the server requested cancellation (the proto's C<is_cancelled>).

=head2 not_found

True when the activity no longer exists according to the server.

=head2 paused

True when the activity was paused.

=head2 reset

True when the activity was reset.

=head2 timed_out

True when the activity timed out.

=head2 worker_shutdown

True when the worker is shutting down and the graceful timeout elapsed.

=head1 FUNCTIONS

=head2 from_proto($reason, $details)

Builds an instance from a C<Cancel> task's C<reason> enum number and its
decoded C<ActivityCancellationDetails> sub-message (which may be C<undef>:
all booleans then stay false). Used by the activity dispatcher.

=cut
