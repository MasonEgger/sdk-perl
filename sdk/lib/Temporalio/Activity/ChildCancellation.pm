# ABOUTME: A fork-safe cancellation token for sync activities running in a
# ABOUTME: forked child (spec section 9.4). It carries NO core FFI pointer — a
# ABOUTME: forked child must never touch the parent's core cancellation token —
# ABOUTME: so it is a plain Perl flag reflecting the cooperative-cancellation
# ABOUTME: state the parent serialized into the invocation struct.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Temporalio::Common::CancellationFuture ();

class Temporalio::Activity::ChildCancellation {
    # The Perl-side cancelled flag. Set from the parent-supplied invocation
    # `cancelled` value, and flippable in-child when a later cancel propagates
    # over the pool's live control channel (spec R19, finding L15).
    field $cancelled :param = 0;

    # Optional live-cancel poll (spec R19): a coderef returning true once a
    # post-dispatch cancel has arrived for this invocation. The fork pool
    # supplies one that drains the child's control-channel frames, so a body
    # polling is_cancelled observes a cancel delivered WHILE it runs — the
    # pre-R19 token was a one-shot boolean captured at dispatch (finding
    # L15). Python parity: sync activities observe a thread/process-safe
    # cancelled_event set after dispatch (sdk-python worker/_activity.py).
    field $poll :param = undef;

    field $future;

    method is_cancelled () {
        return 1 if $cancelled;
        if (defined $poll && $poll->()) {
            $self->cancel;
            return 1;
        }
        return 0;
    }

    method cancel () {
        return if $cancelled;
        $cancelled = 1;
        $future->done if defined $future && !$future->is_ready;
        return;
    }

    # A Future that resolves when cancelled — the same shape as
    # Temporalio::Cancellation->cancelled, so a sync body that (rarely) parks on
    # it behaves consistently. Already-cancelled returns a ready Future. The
    # future resolves when a cancel is OBSERVED (an is_cancelled poll or an
    # explicit cancel), not spontaneously: a synchronous child has no event
    # loop to push the resolution, so a body must poll is_cancelled (or
    # heartbeat) to see a live cancel. Spec R50 (finding T2, R23 clone): each
    # call derives a fresh ->without_cancel view of the shared source future,
    # so a consumer cancel (Future->wait_any's loser sweep) cannot poison it.
    method cancelled () {
        $self->is_cancelled;    # give a live-channel cancel a chance to land
        return Temporalio::Common::CancellationFuture::consumer_future(
            \$future, $cancelled,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Activity::ChildCancellation - fork-safe cancellation for sync activities

=head1 DESCRIPTION

The cancellation token a sync activity sees inside a forked child (spec section
9.4). Unlike L<Temporalio::Cancellation>, it holds B<no> core FFI pointer: a
forked child must never touch the parent's core cancellation token. It is a
plain Perl flag, initialized from the C<cancelled> value the parent serialized
into the L<Temporalio::Activity::Invocation>, and exposes the same
C<is_cancelled> / C<cancel> / C<cancelled> surface as the real token so an
activity body can interrogate it uniformly.

A cancel arriving B<after> dispatch reaches the child through the optional
C<poll> hook (spec R19): each C<is_cancelled> call consults it, and the fork
pool supplies one that drains the pool's live control channel. Because the
child is synchronous (no event loop), the C<cancelled> Future resolves when a
cancel is I<observed> by a poll, not spontaneously — a long-running body
should poll C<is_cancelled> (or heartbeat) periodically.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Activity::ChildCancellation->new(
        cancelled => ...,
        poll      => ...,
    );

Constructs a Temporalio::Activity::ChildCancellation. Named parameters:

=over 4

=item C<cancelled>

(optional, default C<0>)

=item C<poll>

(optional, default C<undef>) A coderef returning true once a post-dispatch
cancel has arrived for this invocation.

=back

=head1 METHODS

=head2 cancel

Marks this child cancellation token as cancelled, signalling the activity body to abort.

=head2 cancelled

Returns a L<Future> that resolves once a cancel has been observed (an
C<is_cancelled> poll, the C<poll> hook consulted by this call, or an explicit
C<cancel>). If the token is already cancelled, returns an already-resolved
Future.

Each call returns a fresh consumer view (via
L<Temporalio::Common::CancellationFuture>) of one shared source future, the
same contract as L<Temporalio::Cancellation/cancelled>: cancelling the
returned Future, as C<< Future->wait_any >>'s loser sweep does when another
component settles first, affects only that view, so C<cancelled> is safe to
race in C<wait_any> (spec R50, finding T2; the R23 fix applied to this
class).

=head2 is_cancelled

Returns true once cancel has been requested.

=cut
