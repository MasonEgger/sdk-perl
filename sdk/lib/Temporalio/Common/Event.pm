# ABOUTME: A one-shot settable event with consumer-safe wait Futures (spec
# ABOUTME: R84): the Perl form of Python's _CompositeEvent (is_set/set/wait).
# ABOUTME: Pure Perl, no FFI — the worker-shutdown signal for activity (R84)
# ABOUTME: and, later, Nexus (R89) contexts rides one of these.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Temporalio::Common::CancellationFuture ();

class Temporalio::Common::Event {
    field $set = 0;
    field $future;    # shared source Future, created lazily by ->wait

    method is_set () { $set ? 1 : 0 }

    # set(): flip the event exactly once and resolve the shared wait future
    # (idempotent; the same set-then-resolve shape as
    # Temporalio::Cancellation::cancel, minus the core token).
    method set () {
        return if $set;
        $set = 1;
        $future->done if defined $future && !$future->is_ready;
        return;
    }

    # wait() -> Future resolving when set() fires (already-resolved if it
    # has). Each call returns a fresh ->without_cancel consumer view of one
    # shared source future (spec R23's Temporalio::Common::CancellationFuture
    # derivation), so a Future->wait_any loser sweep cannot poison the source.
    method wait () {
        return Temporalio::Common::CancellationFuture::consumer_future(
            \$future, $set);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::Event - a one-shot settable event with awaitable Futures

=head1 SYNOPSIS

    use Temporalio::Common::Event ();

    my $event = Temporalio::Common::Event->new;

    my $f = $event->wait;      # Future that resolves when set
    $event->set;               # idempotent
    my $is_set = $event->is_set;

=head1 DESCRIPTION

A minimal one-shot event: initially unset, flipped exactly once by C<set>,
observable synchronously via C<is_set> and asynchronously via the C<wait>
Future. The Perl analog of sdk-python's C<_CompositeEvent>
(C<is_set>/C<set>/C<wait>), introduced for worker-shutdown signalling to
activity contexts (spec R84) and shared with the Nexus shutdown flip (R89).
Pure Perl with only a L<Future> dependency.

=head1 METHODS

=head2 set

Sets the event (once; repeated calls are no-ops) and resolves the shared
wait Future if one has been handed out.

=head2 is_set

Returns true once C<set> has been called.

=head2 wait

Returns a L<Future> that resolves when the event is set (already resolved if
it is). Each call returns a fresh consumer view (via
L<Temporalio::Common::CancellationFuture>) of one shared source future, so
cancelling the returned Future — as C<< Future->wait_any >>'s loser sweep
does — affects only that view and the event stays observable by every other
consumer.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Common::Event (initially unset).

=cut
