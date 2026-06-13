# ABOUTME: Handle to a started/identified workflow (spec section 7.6). v0.1
# ABOUTME: lands the fields only; result/describe/cancel/terminate are P1.11.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Client::WorkflowHandle {
    field $client                 :param;
    field $workflow_id            :param;
    field $run_id                 :param = undef;
    field $first_execution_run_id :param = undef;
    field $result_run_id          :param = undef;

    # Explicit readers (field :reader needs perl 5.40+; floor is 5.38).
    method client                 { $client }
    method workflow_id            { $workflow_id }
    method run_id                 { $run_id }
    method first_execution_run_id { $first_execution_run_id }
    method result_run_id          { $result_run_id }
}

1;

__END__

=head1 NAME

Temporalio::Client::WorkflowHandle - handle to a Temporal workflow execution

=head1 SYNOPSIS

    my $handle = await $client->start_workflow(
        'MyWorkflow', \@args, id => 'wf-1', task_queue => 'demo');

    my $id     = $handle->workflow_id;
    my $run_id = $handle->run_id;

    # Or, without an RPC:
    my $handle = $client->get_workflow_handle('wf-1', run_id => $rid);

=head1 DESCRIPTION

A reference to a single workflow execution (spec section 7.6), returned by
C<< $client->start_workflow >>, C<< ->signal_with_start_workflow >>, and
C<< ->get_workflow_handle >>. It carries the C<workflow_id>, the C<run_id>
(first run id from start, or the run id supplied to
C<get_workflow_handle>), C<first_execution_run_id>, and C<result_run_id>,
plus a back-reference to the owning L<Temporalio::Client>.

v0.1 of this class exposes the identifying fields only. The behavioural
methods (C<result>, C<describe>, C<cancel>, C<terminate>, C<signal>,
C<query>, C<list>/C<count>) land in a later plan step (P1.11+).

=cut
