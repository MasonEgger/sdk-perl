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

# continue_as_new_workflow_execution { ... } — the workflow requested
# continue-as-new (spec section 10.3 step 6). $fields is the already-assembled
# ContinueAsNewWorkflowExecution field hashref (workflow_type, task_queue,
# arguments, retry_policy, memo, headers, search_attributes, the two timeout
# Durations, versioning_intent); the runner owns the payload conversion. Only
# the fields the caller set are present (continue-as-new does NOT re-use the old
# run's arguments — see the proto comment).
sub continue_as_new_workflow_execution ($fields) {
    return _command_class()->new({
        continue_as_new_workflow_execution => $fields,
    });
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

# start_timer { seq, start_to_fire_timeout } — emitted when the workflow body
# calls Temporalio::Workflow::start_timer / sleep (spec section 10.2). $fields
# is the assembled StartTimer field hashref (the runner owns timer-seq
# allocation and the Duration conversion).
sub start_timer ($fields) {
    return _command_class()->new({ start_timer => $fields });
}

# cancel_timer { seq } — emitted when a started timer's Workflow::Future is
# cancelled (spec section 10.3; MUST-match sdk-ruby _apply_cancel_command).
# $seq is the seq of the StartTimer being cancelled.
sub cancel_timer ($seq) {
    return _command_class()->new({ cancel_timer => { seq => $seq } });
}

# respond_to_query { query_id, succeeded|failed } — answers a QueryWorkflow job
# (spec section 10.3; MUST-match sdk-python _apply_query_workflow which sets
# command.respond_to_query.query_id and either .succeeded.response (one result
# payload) or .failed (the converted Failure)). The runner runs the :Query
# handler, then calls this with the query id and either a result payload OR an
# already-converted Failure proto (never both). A query failure is delivered as
# THIS command, never as a workflow/task failure (a dying handler does not fail
# the workflow).
sub respond_to_query ($query_id, %parts) {
    my %variant;
    if (exists $parts{failure}) {
        $variant{failed} = $parts{failure};
    }
    else {
        # Success: QuerySuccess { response: Payload }. A void return leaves the
        # response unset (sdk-python always sends one payload, but the converter
        # may yield undef for a void handler return).
        $variant{succeeded} = {
            (defined $parts{response} ? (response => $parts{response}) : ()),
        };
    }
    return _command_class()->new({
        respond_to_query => {
            query_id => $query_id,
            %variant,
        },
    });
}

# set_patch_marker { patch_id, deprecated } — emitted the first time the
# workflow body calls Temporalio::Workflow::patched($id) (or deprecate_patch)
# and the patch is in use (spec section 10.3 step / versioning; MUST-match
# sdk-python workflow_patch which sets command.set_patch_marker.patch_id /
# .deprecated). The runner owns the use_patch / memoization logic; this builder
# just wraps the marker fields in the command oneof.
sub set_patch_marker ($patch_id, $deprecated = 0) {
    return _command_class()->new({
        set_patch_marker => {
            patch_id   => $patch_id,
            deprecated => ($deprecated ? 1 : 0),
        },
    });
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

The set grows as later phases land (signal/query response commands, child
workflow commands, and so on). This module hosts the completion-outcome
commands (C<complete_workflow_execution>, C<fail_workflow_execution>,
C<cancel_workflow_execution>, C<continue_as_new_workflow_execution>),
C<schedule_activity> (P3.4), and C<start_timer> / C<cancel_timer> (P3.5).

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

=item C<continue_as_new_workflow_execution($fields)>

C<ContinueAsNewWorkflowExecution { ... }> — emitted when the workflow body
calls C<Temporalio::Workflow::continue_as_new>. C<$fields> is the assembled
field hashref (C<workflow_type>, C<task_queue>, C<arguments>, C<retry_policy>,
C<memo>, C<headers>, C<search_attributes>, the two timeout Durations,
C<versioning_intent>); only the fields the caller set are present.

=item C<schedule_activity($fields)>

C<ScheduleActivity { ... }> — emitted when the workflow body calls
C<Temporalio::Workflow::execute_activity> / C<start_activity>. C<$fields> is
the assembled C<ScheduleActivity> field hashref (the runner owns seq
allocation, timeout conversion, and the default task queue).

=item C<start_timer($fields)>

C<StartTimer { seq, start_to_fire_timeout }> — emitted when the workflow body
calls C<Temporalio::Workflow::start_timer> / C<sleep>. C<$fields> is the
assembled C<StartTimer> field hashref (the runner owns the timer-seq allocation
and the C<google.protobuf.Duration> conversion).

=item C<cancel_timer($seq)>

C<CancelTimer { seq }> — emitted when a started timer's
L<Temporalio::Workflow::Future> is cancelled. C<$seq> is the seq of the
C<StartTimer> being cancelled.

=item C<respond_to_query($query_id, %parts)>

C<QueryResult { query_id, succeeded|failed }> — answers a C<QueryWorkflow>
activation job. Pass C<< response => $payload >> for a successful query (the
handler's return value converted to a C<temporal.api.common.v1.Payload>, or
omitted for a void return) or C<< failure => $failure >> for a dying handler
(an already-converted C<temporal.api.failure.v1.Failure>). A query failure is
delivered as this command, never as a workflow or task failure.

=back

=cut
