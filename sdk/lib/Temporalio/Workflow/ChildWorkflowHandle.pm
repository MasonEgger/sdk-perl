# ABOUTME: Handle for an in-flight child workflow (spec section 18) — wraps the
# ABOUTME: two-stage start/result Futures and exposes id/signal/cancel/result.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Workflow::Future ();

# A ChildWorkflowHandle is constructed only by the Runner's start_child_workflow
# (spec section 18.1) — never directly by author code. It wraps the two-stage
# resolution of a child workflow: a START Future (->done once core sends
# ResolveChildWorkflowExecutionStart{succeeded}, carrying the child's run id)
# and a RESULT Future (->done/->fail once core sends ResolveChildWorkflowExecution
# with the terminal outcome). `start_child_workflow` awaits the start Future and
# resolves to this handle; `execute_child_workflow` is sugar over start +
# ->result. The Runner owns the Futures (registers them in
# %pending_child_workflows and resolves them imperatively from activation jobs);
# this class is the author-facing surface plus the on_cancel/on_signal callbacks
# the Runner installs to emit the corresponding commands.
class Temporalio::Workflow::ChildWorkflowHandle {
    # The child workflow id (the resolved id from start_child_workflow — either
    # author-supplied or the deterministic RNG-derived default).
    field $id :param;

    # The StartChildWorkflowExecution seq this handle owns (its child-seq-space
    # identifier). Used by ->cancel/->signal to build the right command.
    field $child_workflow_seq :param;

    # The start Future (->done with $self once the start job's `succeeded` arm
    # arrives; ->fail on `failed`/`cancelled`).
    field $start_future :param;

    # The result Future (->done with the converted result on
    # ResolveChildWorkflowExecution{completed}; ->fail otherwise).
    field $result_future :param;

    # The run id from the start-success job (undef until the start resolves).
    field $first_execution_run_id = undef;

    # Runner-supplied callbacks: on_cancel emits CancelChildWorkflowExecution
    # (unless abandon) and fails the pending Futures with Cancelled; on_signal
    # builds and buffers a SignalExternalWorkflowExecution targeting this child.
    field $on_cancel :param = undef;
    field $on_signal :param = undef;

    method id                     { return $id }
    method child_workflow_seq     { return $child_workflow_seq }
    method start_future           { return $start_future }
    method result_future          { return $result_future }
    method first_execution_run_id { return $first_execution_run_id }

    # Called by the Runner when ResolveChildWorkflowExecutionStart{succeeded}
    # arrives: record the run id, then ->done the start Future with this handle
    # so an awaiting `start_child_workflow` resolves to the handle.
    method _resolve_started ($run_id) {
        $first_execution_run_id = $run_id;
        $start_future->done($self) unless $start_future->is_ready;
        return;
    }

    # result -> the result Future (spec section 18.1). Idempotent: always the
    # same Future, so `await $handle->result` parks on the single terminal
    # resolution. execute_child_workflow awaits this after the start resolves.
    method result { return $result_future }

    # signal($name, %opts) -> a Future resolved when the child signal is
    # acknowledged (spec section 18.1). Delegates to the Runner-installed
    # on_signal callback, which emits a SignalExternalWorkflowExecution on the
    # child_workflow_id arm and registers a pending signal Future. %opts: args
    # (arrayref), headers.
    method signal ($name, %opts) {
        die "Temporalio::Workflow::ChildWorkflowHandle: signal requires a "
          . "Runner context (no on_signal callback installed)"
            unless defined $on_signal;
        return $on_signal->($self, $name, %opts);
    }

    # cancel -> request cancellation of the child (spec section 18.2). Delegates
    # to the Runner-installed on_cancel callback, which emits
    # CancelChildWorkflowExecution { child_workflow_seq } (unless the child is
    # abandon-typed) and, under the cancel chain, fails the pending result await
    # with Cancelled. A no-op once both Futures are already resolved.
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

Temporalio::Workflow::ChildWorkflowHandle - handle for an in-flight child workflow

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use Temporalio::Workflow;

    # await start: resolves to the handle once the child has STARTED.
    my $handle = await Temporalio::Workflow::start_child_workflow(
        'ChildType', id => 'child-1', args => [42],
    );
    $handle->id;                          # 'child-1'
    $handle->first_execution_run_id;      # the child's run id

    await $handle->signal('go', args => ['x']);
    my $result = await $handle->result;   # child return value or mapped failure
    $handle->cancel;                      # request cancellation

=head1 DESCRIPTION

Constructed only by L<Temporalio::Workflow::Runner>'s C<start_child_workflow>
(spec section 18); never instantiated directly. It wraps the two-stage
resolution of a child workflow — a B<start> Future and a B<result> Future — and
exposes the author-facing surface: C<id>, C<first_execution_run_id>,
C<result>, C<signal>, and C<cancel>.

=head1 CONSTRUCTOR

=head2 new

    my $handle = Temporalio::Workflow::ChildWorkflowHandle->new(
        id => ..., child_workflow_seq => ...,
        start_future => ..., result_future => ...,
        on_cancel => sub { ... }, on_signal => sub { ... },
    );

Constructed only by L<Temporalio::Workflow::Runner>; not called by author code.
Wraps the start and result Futures plus the Runner-supplied C<on_cancel> /
C<on_signal> callbacks.

=head1 METHODS

=head2 id

The child workflow id (author-supplied or the deterministic RNG-derived
default).

=head2 child_workflow_seq

The C<StartChildWorkflowExecution> seq this handle owns (its identifier in the
child seq space); used to build the cancel command.

=head2 start_future

The start Future (Runner-owned): C<< ->done >> with this handle once the child
has started.

=head2 result_future

The result Future (Runner-owned): C<< ->done >> / C<< ->fail >> with the child's
terminal outcome. C<result> returns this Future.

=head2 first_execution_run_id

The run id reported by C<ResolveChildWorkflowExecutionStart{succeeded}>;
C<undef> until the start resolves.

=head2 result

The result Future (idempotent): C<await $handle-E<gt>result> parks until the
child reaches a terminal state, then yields the converted return value or
raises the mapped failure (L<Temporalio::Exception::ChildWorkflow>).

=head2 signal

C<signal($name, %opts)> emits a C<SignalExternalWorkflowExecution> targeting
this child (the C<child_workflow_id> oneof arm) and returns a Future resolved
when the signal is acknowledged. C<%opts>: C<args> (arrayref), C<headers>.
Cancelling the returned Future before its resolve emits
C<CancelSignalWorkflow> without pre-emptively raising, exactly as the
external-handle arm (finding R10).

=head2 cancel

Requests cancellation of the child: emits
C<CancelChildWorkflowExecution { child_workflow_seq }> unless the child is
C<abandon>-typed, and fails a pending C<result> await with
L<Temporalio::Exception::Cancelled> under the cancel chain.

=head1 SEE ALSO

L<Temporalio::Workflow>, L<Temporalio::Workflow::Runner>, spec section 18.

=cut
