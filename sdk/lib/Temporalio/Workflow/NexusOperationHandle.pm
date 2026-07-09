# ABOUTME: Handle for an in-flight Nexus operation (spec section 26) — wraps the
# ABOUTME: two-stage start/result Futures and exposes operation_token/result/cancel.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Workflow::Future ();

# A NexusOperationHandle is constructed only by the Runner's start_operation
# (spec section 26.3) — never directly by author code. It mirrors the §18
# child-workflow two-stage shape: a START Future (->done once core sends
# ResolveNexusOperationStart with operation_token (async) or started_sync (sync))
# and a RESULT Future (->done/->fail once core sends ResolveNexusOperation with
# the terminal NexusOperationResult). A NexusClient's start_operation awaits the
# start Future and resolves to this handle; execute_operation is sugar over start
# + ->result. The Runner owns the Futures (registers them in
# %pending_nexus_operation_starts / %pending_nexus_operations and resolves them
# imperatively from activation jobs); this class is the author-facing surface
# plus the on_cancel callback the Runner installs to emit the cancel command.
class Temporalio::Workflow::NexusOperationHandle {
    # The ScheduleNexusOperation seq this handle owns (its nexus-seq-space
    # identifier). Used by ->cancel to build the RequestCancelNexusOperation.
    field $nexus_operation_seq :param;

    # The endpoint / service / operation this handle was scheduled against
    # (carried so the runner can populate a Temporalio::Exception::NexusOperation
    # on a failed/timed-out/cancelled resolve, spec section 26.4).
    field $endpoint :param;
    field $service :param;
    field $operation :param;

    # The start Future (->done_weak with $self once the start job arrives --
    # weak back-reference, spec R29 / finding L5; ->fail on the start `failed`
    # arm).
    field $start_future :param;

    # The result Future (->done with the converted result on
    # ResolveNexusOperation{completed}; ->fail otherwise).
    field $result_future :param;

    # The operation token from the start-success job. For ASYNC operations this
    # is the server-assigned token (ResolveNexusOperationStart{operation_token});
    # for SYNC operations (started_sync) it stays undef (spec section 26.1).
    field $operation_token = undef;

    # Runner-supplied cancel callback: emits RequestCancelNexusOperation (unless
    # abandon) and, under the wait_* cancellation types, stays parked.
    field $on_cancel :param = undef;

    method nexus_operation_seq { return $nexus_operation_seq }
    method endpoint            { return $endpoint }
    method service             { return $service }
    method operation           { return $operation }
    method start_future        { return $start_future }
    method result_future       { return $result_future }
    method operation_token     { return $operation_token }

    # Called by the Runner when ResolveNexusOperationStart arrives. $token is the
    # async operation token, or undef for a started_sync (synchronous) op. Record
    # the token, then resolve the start Future with this handle so an awaiting
    # start_operation resolves to the handle. done_weak, not ->done (spec R29,
    # finding L5): the future's result is a weak back-reference, because this
    # handle owns the future (start_future field + the Runner closures) and a
    # strong result formed an uncollectable handle <-> start-future cycle.
    method _resolve_started ($token) {
        $operation_token = $token;
        $start_future->done_weak($self) unless $start_future->is_ready;
        return;
    }

    # result -> the result Future (spec section 26.1). Idempotent: always the
    # same Future, so `await $handle->result` parks on the single terminal
    # resolution. execute_operation awaits this after the start resolves.
    method result { return $result_future }

    # cancel -> request cancellation of the operation (spec section 26.3).
    # Delegates to the Runner-installed on_cancel callback, which emits
    # RequestCancelNexusOperation { seq } (unless the op is abandon-typed). A
    # no-op once both Futures are already resolved.
    method cancel {
        return unless defined $on_cancel;
        $on_cancel->($self);
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::NexusOperationHandle - handle for an in-flight Nexus operation

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use Temporalio::Workflow;

    my $nc = Temporalio::Workflow::create_nexus_client(
        endpoint => 'my-endpoint', service => 'my-service');

    # await start: resolves to the handle once the operation has STARTED.
    my $handle = await $nc->start_operation('say-hello', 'world');
    $handle->operation_token;             # async op: token; sync op: undef
    my $result = await $handle->result;   # operation result or mapped failure
    $handle->cancel;                      # request cancellation

=head1 DESCRIPTION

Constructed only by L<Temporalio::Workflow::Runner>'s C<start_operation> (spec
section 26); never instantiated directly. It wraps the two-stage resolution of a
Nexus operation, mirroring L<Temporalio::Workflow::ChildWorkflowHandle>: a
B<start> Future and a B<result> Future. It exposes the author-facing surface:
C<operation_token>, C<result>, and C<cancel>.

=head1 CONSTRUCTOR

=head2 new

    my $handle = Temporalio::Workflow::NexusOperationHandle->new(
        nexus_operation_seq => ...,
        start_future => ..., result_future => ...,
        on_cancel => sub { ... },
    );

Constructed only by L<Temporalio::Workflow::Runner>; not called by author code.

=head1 METHODS

=head2 nexus_operation_seq

The C<ScheduleNexusOperation> seq this handle owns (its identifier in the nexus
seq space); used to build the cancel command.

=head2 endpoint

The Nexus endpoint name this operation was scheduled against.

=head2 service

The Nexus service name this operation was scheduled against.

=head2 operation

The Nexus operation name this handle was scheduled for.

=head2 start_future

The start Future (Runner-owned): resolved with this handle once the operation
has started. The resolved future holds the handle only B<weakly>
(L<Temporalio::Workflow::Future/done_weak>, spec R29 / finding L5), so it
never keeps the handle alive on its own; it yields the handle for as long as
the awaiting caller or the Runner holds a strong reference.

=head2 result_future

The result Future (Runner-owned): C<< ->done >> / C<< ->fail >> with the
operation's terminal outcome. C<result> returns this Future.

=head2 operation_token

The operation token reported by C<ResolveNexusOperationStart{operation_token}>
for an asynchronous operation; C<undef> for a synchronous (C<started_sync>)
operation or until the start resolves.

=head2 result

The result Future (idempotent): C<await $handle-E<gt>result> parks until the
operation reaches a terminal state, then yields the converted return value or
raises the mapped failure (L<Temporalio::Exception::NexusOperation>).

=head2 cancel

Requests cancellation of the operation: emits
C<RequestCancelNexusOperation { seq }> unless the operation is C<abandon>-typed.

=head1 SEE ALSO

L<Temporalio::Workflow>, L<Temporalio::Workflow::NexusClient>,
L<Temporalio::Workflow::Runner>, spec section 26.

=cut
