# ABOUTME: Handle for an arbitrary already-running workflow (spec section 20) —
# ABOUTME: in-workflow signal/cancel of an external execution via the command stream.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

# An ExternalWorkflowHandle is constructed only by the Runner's
# get_external_workflow_handle (spec section 20.1) — never directly by author
# code. It captures the target ($workflow_id, $run_id) plus the runner reference
# and emits NO command; it is the in-workflow counterpart to the client-side
# WorkflowHandle->signal/->cancel, distinct from a child handle (the target was
# not started by this run). signal/cancel delegate back to the runner, which
# emits SignalExternalWorkflowExecution / RequestCancelExternalWorkflowExecution
# on the workflow_execution oneof arm (the namespace is the runner's own, never
# a user argument) and resolves the returned Workflow::Future on the matching
# Resolve* job.
class Temporalio::Workflow::ExternalWorkflowHandle {
    # The target workflow id.
    field $workflow_id :param;

    # The target run id (undef targets the most recent run; emitted as an empty
    # string in the NamespacedWorkflowExecution).
    field $run_id :param = undef;

    # The owning Temporalio::Workflow::Runner — the signal/cancel methods
    # delegate to its _signal_external_workflow / _request_cancel_external_workflow,
    # which own seq allocation, namespace injection, and command emission.
    field $runner :param;

    method workflow_id { return $workflow_id }
    method run_id      { return $run_id }

    # signal($name, %opts) -> a Workflow::Future resolved when the signal send is
    # acknowledged (ResolveSignalExternalWorkflow). %opts: args (arrayref),
    # headers. Emits SignalExternalWorkflowExecution on the workflow_execution
    # arm. Cancelling the returned Future before its resolve emits
    # CancelSignalWorkflow{seq} without pre-emptively raising (spec section 20.2).
    # `await`ing it satisfies the async contract.
    method signal ($name, %opts) {
        return $runner->_signal_external_workflow(
            $workflow_id, $run_id, $name, %opts);
    }

    # cancel(%opts) -> a Workflow::Future resolved when the cancel request is
    # acknowledged (ResolveRequestCancelExternalWorkflow). Emits
    # RequestCancelExternalWorkflowExecution on the workflow_execution arm. A
    # cancel request has no counter-cancel (spec section 20.2).
    method cancel (%opts) {
        return $runner->_request_cancel_external_workflow(
            $workflow_id, $run_id, %opts);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::ExternalWorkflowHandle - handle for an arbitrary running workflow

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use Temporalio::Workflow;

    my $h = Temporalio::Workflow::get_external_workflow_handle(
        'other-wf', run_id => undef);
    $h->workflow_id;   # 'other-wf'
    $h->run_id;        # undef (most-recent run)

    await $h->signal('go', args => ['x']);   # SignalExternalWorkflowExecution
    await $h->cancel;                        # RequestCancelExternalWorkflowExecution

=head1 DESCRIPTION

Constructed only by L<Temporalio::Workflow::Runner>'s
C<get_external_workflow_handle> (spec section 20); never instantiated directly.
A workflow body obtains a handle to an arbitrary already-running workflow (by
id, in the current namespace) and signals or cancels it B<through the command
stream> — never via a client RPC. This is the in-workflow counterpart to the
client-side L<Temporalio::Client::WorkflowHandle>'s C<signal>/C<cancel>, and is
distinct from a child workflow handle (an external handle targets a workflow
this run did not start).

The constructor is synchronous and emits no command. C<signal> and C<cancel>
each emit one command (on the C<workflow_execution> oneof arm of the proto, with
the namespace taken from the running workflow's own namespace) and return a
L<Temporalio::Workflow::Future> that resolves to nothing on success, or fails
with the converted server failure (a not-found surfaces as
L<Temporalio::Exception::Application>).

=head1 CONSTRUCTOR

=head2 new

    my $h = Temporalio::Workflow::ExternalWorkflowHandle->new(
        workflow_id => ..., run_id => ..., runner => ...,
    );

Constructed only by L<Temporalio::Workflow::Runner>; not called by author code.

=head1 METHODS

=head2 workflow_id

The target workflow id.

=head2 run_id

The target run id (C<undef> targets the most-recent run).

=head2 signal

C<signal($name, %opts)> emits a C<SignalExternalWorkflowExecution> targeting
this workflow (the C<workflow_execution> oneof arm) and returns a
L<Temporalio::Workflow::Future> resolved when the signal is acknowledged.
C<%opts>: C<args> (arrayref), C<headers>. Cancelling the returned Future before
its resolve emits C<CancelSignalWorkflow> without pre-emptively raising.

=head2 cancel

C<cancel> emits a C<RequestCancelExternalWorkflowExecution> targeting this
workflow and returns a L<Temporalio::Workflow::Future> resolved when the cancel
request is acknowledged.

=head1 SEE ALSO

L<Temporalio::Workflow>, L<Temporalio::Workflow::Runner>, spec section 20.

=cut
