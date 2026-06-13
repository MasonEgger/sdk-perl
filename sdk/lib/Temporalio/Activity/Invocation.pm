# ABOUTME: The cross-fork activity invocation struct (spec section 9.4): a
# ABOUTME: serializable plain-data record sent to a forked sync-activity child.
# ABOUTME: Carries ONLY plain scalars/refs — activity type, already-converted
# ABOUTME: args, the ActivityInfo hashref, the task token, and the cancelled
# ABOUTME: flag. NO live core pointers, Cancellation objects, or data converters
# ABOUTME: cross the fork boundary (REFACTOR P2.5.3).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Storable ();

class Temporalio::Activity::Invocation {
    # The registered activity type name the child looks the body up by.
    field $activity_type :param;

    # The activity arguments, ALREADY converted from payloads to plain Perl
    # scalars by the parent (spec section 8.4 step 4 happens in the parent so
    # the child never touches protobuf or the codec chain — the converters
    # hold no fork-safe state).
    field $args :param = [];

    # The frozen ActivityInfo hashref (spec section 9.3) the child exposes via
    # its reconstructed Activity::Context.
    field $info :param = {};

    # The activity's task token (also present in info; kept top-level so the
    # parent's heartbeat relay can key on it without unpacking info).
    field $task_token :param;

    # Cooperative cancellation: the parent sets this true when a cancel arrives
    # before/while the child runs. The child's reconstructed Context exposes a
    # cancellation token whose is_cancelled reflects this flag (spec section
    # 9.4 — a forked child cannot share the parent's core cancellation token).
    field $cancelled :param = 0;

    method activity_type { $activity_type }
    method args          { $args }
    method info          { $info }
    method task_token    { $task_token }
    method is_cancelled  { $cancelled ? 1 : 0 }

    # freeze -> a plain (non-ref) serialized scalar safe to hand across the
    # IO::Async::Function channel. Storable round-trips nested arrayrefs/hashrefs
    # of plain scalars losslessly, which is exactly the converted-args shape.
    method freeze {
        return Storable::freeze({
            activity_type => $activity_type,
            args          => $args,
            info          => $info,
            task_token    => $task_token,
            cancelled     => $cancelled ? 1 : 0,
        });
    }

    # thaw($frozen) -> a reconstructed Invocation (used on the child side).
    sub thaw ($class, $frozen) {
        my $h = Storable::thaw($frozen);
        return $class->new(
            activity_type => $h->{activity_type},
            args          => $h->{args},
            info          => $h->{info},
            task_token    => $h->{task_token},
            cancelled     => $h->{cancelled},
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Activity::Invocation - serializable cross-fork activity invocation

=head1 SYNOPSIS

    my $inv = Temporalio::Activity::Invocation->new(
        activity_type => 'send_email',
        args          => [ 'to@example.com', 'Subject', 'Body' ],
        info          => { task_token => $token, activity_id => 'a-1', ... },
        task_token    => $token,
        cancelled     => 0,
    );

    my $frozen = $inv->freeze;                 # plain scalar, fork-safe
    my $child  = Temporalio::Activity::Invocation->thaw($frozen);

=head1 DESCRIPTION

The payload the sync-activity fork pool (L<Temporalio::Activity::Pool>, spec
section 9.4) sends to a forked child. It is deliberately a plain-data record:
the activity type name, the activity arguments B<already converted> from
payloads to Perl scalars by the parent, the frozen C<ActivityInfo> hashref,
the task token, and the cooperative-cancellation flag.

No live core pointers, L<Temporalio::Cancellation> objects, or
L<Temporalio::Converter::Data> instances cross the fork boundary — those hold
state that is not fork-safe (FFI pointers, the eventfd-backed callback queue).
The parent does all protobuf and codec work; the child only runs the Perl
body. L</freeze> / L</thaw> use L<Storable> to round-trip the record across
the L<IO::Async::Function> channel.

=cut
