# ABOUTME: Derives per-consumer views of a shared cancellation Future so a
# ABOUTME: Future->wait_any loser sweep cannot poison the shared source
# ABOUTME: (spec R23/R50, findings R2/T2). Pure Perl, no FFI dependency, so
# ABOUTME: the fork-safe Activity::ChildCancellation can load it too.
use v5.38;
use warnings;

package Temporalio::Common::CancellationFuture;

use Future ();

# The shared source future lives in the owning token; this helper creates it
# lazily through $source_ref and hands each consumer a ->without_cancel view.
# Cancelling a view (as Future->wait_any's loser sweep does when another
# component settles first) settles only that consumer's copy: the source
# stays pending, and the token's cancel() still resolves every other
# consumer, held or future. Pre-fix, both Temporalio::Cancellation and
# Temporalio::Activity::ChildCancellation handed every consumer the ONE
# shared future; a swept consumer cancelled it, cancel()'s
# `!$future->is_ready` guard then skipped ->done (cancelled counts as
# ready), and cancellation was never observable again (finding R2, =A4=L31a;
# finding T2 for the ChildCancellation clone).
sub consumer_future ($source_ref, $already_cancelled) {
    $$source_ref //= $already_cancelled ? Future->done : Future->new;
    return $$source_ref->without_cancel;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::CancellationFuture - consumer-safe views of a shared cancellation Future

=head1 SYNOPSIS

    use Temporalio::Common::CancellationFuture ();

    # inside a token class with `field $future` and `field $cancelled`:
    method cancelled () {
        return Temporalio::Common::CancellationFuture::consumer_future(
            \$future, $cancelled,
        );
    }

=head1 DESCRIPTION

The shared derivation behind C<cancelled()> on L<Temporalio::Cancellation>
and L<Temporalio::Activity::ChildCancellation> (spec R23 and R50).
One pending source Future per token carries the resolution; every consumer
gets a fresh C<< ->without_cancel >> view of it, so a consumer-side cancel
(most commonly C<< Future->wait_any >>'s loser sweep when another component
settles first) cannot poison the source.
This module is pure Perl with only a L<Future> dependency, so the fork-safe
child token can use it without pulling in core FFI bindings.

=head1 FUNCTIONS

=head2 consumer_future

    my $view = Temporalio::Common::CancellationFuture::consumer_future(
        \$source_future, $already_cancelled,
    );

Lazily creates the shared source Future through the scalar reference (an
already-resolved C<< Future->done >> when C<$already_cancelled> is true,
otherwise a pending Future) and returns a per-call C<< ->without_cancel >>
view of it.
The returned Future resolves when the source does; cancelling it settles
only that view and leaves the source pending, so callers may race it in
C<< Future->wait_any >> freely.

=cut
