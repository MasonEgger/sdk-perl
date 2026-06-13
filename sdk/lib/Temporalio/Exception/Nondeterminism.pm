# ABOUTME: Raised when a workflow activation contradicts the recorded history —
# ABOUTME: e.g. a ResolveActivity/FireTimer for a seq the workflow never emitted
# ABOUTME: (spec section 10.3 / T-wf-13). Whether it fails the TASK or the WORKFLOW
# ABOUTME: is governed by the worker's nondeterminism_as_workflow_fail option.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Nondeterminism :isa(Temporalio::Exception) {
    # No extra fields: the message carries the offending detail (e.g. the seq).
    # The runner's outcome decision table special-cases this class so that, by
    # default, a non-determinism error fails the workflow TASK (the server
    # retries), and only fails the WORKFLOW when nondeterminism_as_workflow_fail
    # is set (spec section 10.3 step 6 / T-wf-13).
}

1;

__END__

=head1 NAME

Temporalio::Exception::Nondeterminism - workflow replay contradicted history

=head1 DESCRIPTION

Raised by L<Temporalio::Workflow::Runner> when an activation job cannot be
matched against the workflow's emitted commands — for example a
C<ResolveActivity> or C<FireTimer> for a sequence number the workflow never
allocated (spec section 10.3, test T-wf-13).

Unlike other C<Temporalio::Exception::*> subclasses, a non-determinism error
does B<not> unconditionally fail the workflow execution. The runner's outcome
decision table (spec section 10.3 step 6) routes it to a workflow-B<task>
failure by default (the server retries the task), and only to
C<FailWorkflowExecution> when the worker's C<nondeterminism_as_workflow_fail>
option is set. See L<Temporalio::Exception> for the shared C<message>,
C<stack_trace>, and C<cause> fields.

=cut
