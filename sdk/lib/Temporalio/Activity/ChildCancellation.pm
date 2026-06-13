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

class Temporalio::Activity::ChildCancellation {
    # The Perl-side cancelled flag. Set from the parent-supplied invocation
    # `cancelled` value, and flippable in-child if a later cancel propagates.
    field $cancelled :param = 0;
    field $future;

    method is_cancelled () { $cancelled ? 1 : 0 }

    method cancel () {
        return if $cancelled;
        $cancelled = 1;
        $future->done if defined $future && !$future->is_ready;
        return;
    }

    # A Future that resolves when cancelled — the same shape as
    # Temporalio::Cancellation->cancelled, so a sync body that (rarely) parks on
    # it behaves consistently. Already-cancelled returns a ready Future.
    method cancelled () {
        $future //= $cancelled ? Future->done : Future->new;
        return $future;
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

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Activity::ChildCancellation->new(
        cancelled => ...,
    );

Constructs a Temporalio::Activity::ChildCancellation. Named parameters:

=over 4

=item C<cancelled>

(optional, default C<0>)

=back

=head1 METHODS

=head2 cancel

Marks this child cancellation token as cancelled, signalling the activity body to abort.

=head2 cancelled

Accessor returning the truthy cancelled flag.

=head2 is_cancelled

Returns true once cancel has been requested.

=cut
