# ABOUTME: Failure raised when starting a workflow that is already running.
# ABOUTME: Identifies the conflicting execution by id, type, and run id (spec 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::WorkflowAlreadyStarted :isa(Temporalio::Exception) {
    field $workflow_id :param = undef;
    field $workflow_type :param = undef;
    field $run_id :param = undef;

    method workflow_id            { $workflow_id }
    method workflow_type          { $workflow_type }
    method run_id                 { $run_id }
}

1;

__END__

=head1 NAME

Temporalio::Exception::WorkflowAlreadyStarted - Failure raised when starting a workflow that is already running.

=head1 DESCRIPTION

Raised by C<start_workflow> when a workflow with the same id is already running and the id-reuse/conflict policy rejects the new start. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
