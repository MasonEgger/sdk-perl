# ABOUTME: Builders for coresdk WorkflowCommand protos (spec section 10.3) — the
# ABOUTME: outbound commands the runner buffers and drains into a completion.
package Temporalio::Workflow::Commands;

use v5.38;
use warnings;

use Temporalio::Core::Proto ();

# The generated WorkflowCommand class — a oneof over every command variant
# (complete_workflow_execution, fail_workflow_execution, schedule_activity,
# start_timer, ...). Each builder here returns a fully-formed WorkflowCommand
# with exactly one variant set. The runner buffers these and drops them into a
# Success.commands list at completion time. Resolving the class triggers the
# one-time vendored-proto load.
sub _command_class {
    return Temporalio::Core::Proto::resolve(
        'coresdk.workflow_commands.WorkflowCommand');
}

# complete_workflow_execution { result } — the workflow's :Run returned a
# value. $result_payload is a temporal.api.common.v1.Payload (or undef for a
# bare/void return; the proto leaves the field unset then).
sub complete_workflow_execution ($result_payload) {
    return _command_class()->new({
        complete_workflow_execution => {
            (defined $result_payload ? (result => $result_payload) : ()),
        },
    });
}

# fail_workflow_execution { failure } — a Temporal failure escaped :Run. The
# caller passes an already-converted temporal.api.failure.v1.Failure proto.
sub fail_workflow_execution ($failure) {
    return _command_class()->new({
        fail_workflow_execution => {
            (defined $failure ? (failure => $failure) : ()),
        },
    });
}

# cancel_workflow_execution {} — a Cancelled exception escaped :Run after a
# CancelWorkflow job (de facto spec: NOT a fail). No fields.
sub cancel_workflow_execution () {
    return _command_class()->new({ cancel_workflow_execution => {} });
}

# schedule_activity { ... } — emitted when the workflow body calls
# Temporalio::Workflow::execute_activity / start_activity (spec section 10.2).
# $fields is the already-assembled ScheduleActivity field hashref (seq,
# activity_id, activity_type, task_queue, arguments, the four timeout Durations,
# retry_policy, cancellation_type, headers, ...). The runner builds the field
# set (it owns seq allocation, timeout conversion, and the default task queue);
# this builder just wraps it in the command oneof so the construction site
# stays consistent with the other command builders.
sub schedule_activity ($fields) {
    return _command_class()->new({ schedule_activity => $fields });
}

1;

__END__

=head1 NAME

Temporalio::Workflow::Commands - builders for coresdk WorkflowCommand protos

=head1 SYNOPSIS

    use Temporalio::Workflow::Commands ();

    my $cmd = Temporalio::Workflow::Commands::complete_workflow_execution(
        $result_payload);
    # $cmd->which_variant eq 'complete_workflow_execution'

=head1 DESCRIPTION

Thin builders over the generated C<coresdk.workflow_commands.WorkflowCommand>
oneof message (spec section 10.3). Each function returns a C<WorkflowCommand>
with exactly one variant set; the L<Temporalio::Workflow::Runner> buffers them
during an activation and drains the buffer into the
C<WorkflowActivationCompletion> it returns to the worker.

The set grows as later phases land: C<start_timer> / C<cancel_timer> (P3.5),
C<continue_as_new_workflow_execution> (P3.7), and so on. This module hosts the
completion-outcome commands and C<schedule_activity> (P3.4).

=head1 FUNCTIONS

=over 4

=item C<complete_workflow_execution($result_payload)>

C<CompleteWorkflowExecution { result }>. C<$result_payload> is a
C<temporal.api.common.v1.Payload> (or C<undef> for a void return, leaving the
field unset).

=item C<fail_workflow_execution($failure)>

C<FailWorkflowExecution { failure }>, given an already-converted
C<temporal.api.failure.v1.Failure> proto.

=item C<cancel_workflow_execution()>

C<CancelWorkflowExecution {}> — the cancellation outcome (de facto Temporal
spec: a C<Cancelled> escape after C<CancelWorkflow> is NOT a failure).

=item C<schedule_activity($fields)>

C<ScheduleActivity { ... }> — emitted when the workflow body calls
C<Temporalio::Workflow::execute_activity> / C<start_activity>. C<$fields> is
the assembled C<ScheduleActivity> field hashref (the runner owns seq
allocation, timeout conversion, and the default task queue).

=back

=cut
