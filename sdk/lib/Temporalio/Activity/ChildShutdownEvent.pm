# ABOUTME: A fork-safe worker-shutdown event for sync activities running in a
# ABOUTME: forked child (spec R84, spec I7 direction A / GitHub #7). Mirrors
# ABOUTME: Temporalio::Activity::ChildCancellation's shape (a plain Perl flag
# ABOUTME: plus an optional live-channel poll hook) but for the is_set/set/wait
# ABOUTME: surface Temporalio::Activity::Context expects from a
# ABOUTME: worker_shutdown_event, so a pooled child's Context can report
# ABOUTME: is_worker_shutdown/wait_for_worker_shutdown without a live
# ABOUTME: Temporalio::Common::Event shared across the fork boundary (which a
# ABOUTME: forked child cannot hold).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Temporalio::Common::CancellationFuture ();

class Temporalio::Activity::ChildShutdownEvent {
    # The Perl-side set flag. Flippable in-child when the pool's control
    # channel relays a 'shutdown' frame (spec I7: Pool->notify_shutdown
    # broadcasts one to every connected child when the worker begins
    # shutdown, mirroring ActivityDispatcher's own
    # $worker_shutdown_event->set for async activities, spec R84).
    field $set :param = 0;

    # Optional live-channel poll (mirrors ChildCancellation's poll): a
    # coderef returning true once a 'shutdown' frame has arrived for this
    # child. Consulted on every is_set/wait call, the same natural
    # observation points a synchronous body has (is_cancelled polls,
    # heartbeats); there is no event loop in the child to push this
    # spontaneously.
    field $poll :param = undef;

    field $future;

    method is_set () {
        return 1 if $set;
        if (defined $poll && $poll->()) {
            $self->set;
        }
        return $set ? 1 : 0;
    }

    method set () {
        return if $set;
        $set = 1;
        $future->done if defined $future && !$future->is_ready;
        return;
    }

    # A Future resolving once set (already-resolved if already set), the same
    # consumer-safe derivation as ChildCancellation->cancelled (spec R50,
    # finding T2) so a Future->wait_any loser sweep cannot poison the shared
    # source future.
    method wait () {
        $self->is_set;    # give a live-channel shutdown frame a chance to land
        return Temporalio::Common::CancellationFuture::consumer_future(
            \$future, $set,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Activity::ChildShutdownEvent - fork-safe worker-shutdown event for sync activities

=head1 DESCRIPTION

The worker-shutdown signal a sync activity sees inside a forked child (spec
R84, spec I7 direction A). Unlike L<Temporalio::Common::Event>, which a
dispatcher shares BY REFERENCE with every async activity's Context, a forked
child cannot observe the parent's live event object across the fork boundary.
This class exposes the same C<is_set>/C<set>/C<wait> surface
L<Temporalio::Activity::Context> expects from its C<worker_shutdown_event>,
backed instead by an optional C<poll> hook the fork pool supplies: each call
drains the pool's control channel for a 'shutdown' frame broadcast by
L<Temporalio::Activity::Pool/notify_shutdown>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Activity::ChildShutdownEvent->new(
        set  => ...,
        poll => ...,
    );

Constructs a Temporalio::Activity::ChildShutdownEvent. Named parameters:

=over 4

=item C<set>

(optional, default C<0>)

=item C<poll>

(optional, default C<undef>) A coderef returning true once a 'shutdown' frame
has arrived over the pool's control channel.

=back

=head1 METHODS

=head2 is_set

Returns true once C<set> has been called, consulting C<poll> first when one
was supplied.

=head2 set

Sets the event (once; repeated calls are no-ops) and resolves the shared
C<wait> Future if one has been handed out.

=head2 wait

Returns a L<Future> that resolves once the event is set (already resolved if
it is). Each call returns a fresh consumer view of one shared source future
(spec R50), safe to race in C<< Future->wait_any >>.

=cut
