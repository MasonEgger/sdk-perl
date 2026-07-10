# ABOUTME: Temporalio::Workflow::Future (spec section 10.3) — the manually
# ABOUTME: resolved, deterministic Future subclass that the workflow runner
# ABOUTME: drives imperatively from activation jobs, NEVER via IO::Async.
package Temporalio::Workflow::Future;
use v5.38;
use warnings;

use parent -norequire, 'Future';
use Future ();
use Scalar::Util ();

# A subclass of the CPAN Future module. The workflow runner resolves these
# imperatively (->done / ->fail from activation jobs) rather than via the
# IO::Async loop, and Future's on_ready callbacks — which are the
# continuations registered by Future::AsyncAwait await — run synchronously at
# resolve time, so the deterministic pump observes progress in a defined
# order. Cancellation hooks registered with Future's real on_cancel API fire
# in reverse-registration order on ->cancel; the runner relies on that
# ordering for nested cancellation chains (e.g. a child future cancelling its
# parent's emitted command before the parent's own teardown). is_workflow_future
# lets interceptors distinguish these from ordinary Futures.
sub is_workflow_future { 1 }

# done_weak($owner) -> $self (spec R29, finding L5). Resolve exactly as ->done,
# then weaken the stored copy of $owner, for the one shape ->done cannot
# survive: a future resolved with the object that OWNS it. Both handle classes
# (ChildWorkflowHandle, NexusOperationHandle) resolve their start future with
# the handle itself; the future's strong result plus the handle's strong
# start_future field (and the Runner closures capturing the future) formed an
# uncollectable cycle pinning handle + futures per child/nexus start. With the
# weak back-reference, the future yields the handle for as long as any strong
# ref (the awaiting caller, the Runner's pending map) keeps it alive, and
# ->get returns undef only once every strong ref is gone. This is the single,
# centralized owner-for-result exchange point: any NEW site that resolves a
# future with its owner must go through done_weak, never ->done.
sub done_weak {
    my ($self, $owner) = @_;
    $self->done($owner);
    # CPAN Future (pure Perl, the backend pinned by this SDK) stores done
    # values in the 'result' slot; weaken the back-reference in place. Guarded
    # so a non-hash backend (e.g. a future Future::XS swap) or a ->done that
    # stored nothing (already-cancelled future) degrades to the old strong
    # behaviour instead of crashing.
    if ((Scalar::Util::reftype($self) // '') eq 'HASH'
        && ref $self->{result}
        && ref $self->{result}[0]) {
        Scalar::Util::weaken($self->{result}[0]);
    }
    return $self;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::Future - manually-resolved deterministic Future subclass

=head1 SYNOPSIS

    use Temporalio::Workflow::Future ();

    my $f = Temporalio::Workflow::Future->new;

    # workflow body (under Future::AsyncAwait):
    my $value = await $f;

    # the runner, from an activation job, resolves imperatively:
    $f->done($value);    # awaiting continuations run synchronously here

    # cancellation hooks fire in reverse-registration order:
    $f->on_cancel(sub { ... });   # registered first, fires last
    $f->cancel;

=head1 DESCRIPTION

A subclass of the CPAN L<Future> module used as the core primitive of the
custom deterministic workflow scheduler (spec section 10.3). Workflow code
C<await>s these futures, but unlike ordinary L<Future::AsyncAwait> futures
they are B<not> tied to the IO::Async event loop: the
L<Temporalio::Workflow::Runner> resolves them imperatively
(C<< ->done >> / C<< ->fail >>) while applying activation jobs.

Because L<Future>'s C<on_ready> callbacks (which are the continuations
Future::AsyncAwait registers for an C<await>) run B<synchronously> at the
moment of resolution, calling C<< ->done >> / C<< ->fail >> makes the
awaiting workflow code runnable immediately and deterministically, with no
trip through the event loop. This is what lets the runner's pump loop drive
workflow progress in a fixed, replay-safe order.

=head1 METHODS

This class inherits the full L<Future> API. It adds:

=head2 is_workflow_future

Always returns true. Interceptors and the runner use this to distinguish a
workflow future from an ordinary L<Future> (e.g. one created by client code).

=head2 done_weak

    $f->done_weak($owner);

Resolves the future with C<$owner> exactly as C<< ->done >>, then weakens the
stored copy (spec R29, finding L5). For the one shape a strong result cannot
survive: a future resolved with the object that B<owns> it, such as a handle
resolving its own start future
(L<Temporalio::Workflow::ChildWorkflowHandle>,
L<Temporalio::Workflow::NexusOperationHandle>). With a strong result the
handle and its start future pinned each other in an uncollectable cycle; with
the weak back-reference the future yields the owner for as long as any strong
reference (the awaiting caller, the runner's pending maps) keeps it alive, and
C<< ->get >> returns C<undef> once every strong reference is gone. Any new
site that resolves a future with its owner must use C<done_weak>, never
C<< ->done >>.

=head1 CANCELLATION ORDERING

Cancellation hooks are registered via L<Future>'s real C<on_cancel> API. On
C<< ->cancel >>, L<Future> fires them in B<reverse-registration order> (the
last hook registered runs first). The workflow runner relies on this for
nested cancellation chains: a hook that emits a C<CancelActivity> /
C<CancelTimer> / C<RequestCancelExternalWorkflowExecution> command runs before
any earlier-registered cleanup that depends on it.

=head1 SEE ALSO

L<Future>, L<Temporalio::Workflow::Runner> (the runner that resolves these),
spec section 10.3.

=cut
