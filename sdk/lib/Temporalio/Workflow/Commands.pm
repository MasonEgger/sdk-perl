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

# request_cancel_activity { seq } — emitted when a scheduled activity's
# Workflow::Future is cancelled (spec section 10.3 / T-act-9; MUST-match
# sdk-python _ActivityHandle._apply_cancel_command, which sets
# command.request_cancel_activity.seq). $seq is the seq of the ScheduleActivity
# being cancelled. Core forwards the cancellation to the activity per the
# activity's ActivityCancellationType: TRY_CANCEL / WAIT_CANCELLATION_COMPLETED
# tell the running activity to cancel; ABANDON never emits this command at all
# (the workflow stops waiting without asking core to cancel the activity — see
# Temporalio::Workflow::Runner::_ActivityFuture).
sub request_cancel_activity ($seq) {
    return _command_class()->new({ request_cancel_activity => { seq => $seq } });
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

# start_child_workflow_execution { ... } — emitted when the workflow body calls
# Temporalio::Workflow::execute_child_workflow / start_child_workflow (spec
# section 18). $fields is the already-assembled StartChildWorkflowExecution
# field hashref (seq, namespace, workflow_id, workflow_type, task_queue, input,
# the three timeout Durations, parent_close_policy, workflow_id_reuse_policy,
# retry_policy, cron_schedule, headers, memo, search_attributes,
# cancellation_type). The runner owns seq allocation, payload conversion, the
# default id/task_queue, and the enum string -> number mapping; this builder
# just wraps the field set in the command oneof.
sub start_child_workflow_execution ($fields) {
    return _command_class()->new({ start_child_workflow_execution => $fields });
}

# cancel_child_workflow_execution { child_workflow_seq, reason } — emitted when
# a ChildWorkflowHandle is cancelled (spec section 18.2; MUST-match the
# StartChildWorkflowExecution proto, which keys this on `child_workflow_seq`
# rather than the activity/timer `seq`). $seq is the seq of the
# StartChildWorkflowExecution being cancelled. ABANDON-typed children never
# emit this command (the workflow stops waiting without asking core to cancel
# the child — see Temporalio::Workflow::Runner's child-handle cancel hook).
sub cancel_child_workflow_execution ($seq, $reason = undef) {
    return _command_class()->new({
        cancel_child_workflow_execution => {
            child_workflow_seq => $seq,
            (defined $reason ? (reason => $reason) : ()),
        },
    });
}

# signal_external_workflow_execution { seq, child_workflow_id|workflow_execution,
# signal_name, args, headers } — emitted when a ChildWorkflowHandle's ->signal
# (spec section 18) or an ExternalWorkflowHandle's ->signal (spec section 20) is
# called. $fields is the assembled field hashref. A child-targeted signal sets
# the `child_workflow_id` oneof arm; an external-handle signal sets the
# `workflow_execution` arm (a NamespacedWorkflowExecution). The runner owns seq
# allocation, namespace injection, and payload conversion.
sub signal_external_workflow_execution ($fields) {
    return _command_class()->new({
        signal_external_workflow_execution => $fields,
    });
}

# request_cancel_external_workflow_execution { seq, workflow_execution, reason }
# — emitted when an ExternalWorkflowHandle's ->cancel is called (spec section
# 20). $fields is the assembled field hashref (seq, workflow_execution =
# NamespacedWorkflowExecution{namespace, workflow_id, run_id}; reason is unset).
# The runner owns external-cancel seq allocation and namespace injection.
sub request_cancel_external_workflow_execution ($fields) {
    return _command_class()->new({
        request_cancel_external_workflow_execution => $fields,
    });
}

# cancel_signal_workflow { seq } — emitted when an in-flight
# SignalExternalWorkflowExecution's awaiting frame is cancelled before its
# ResolveSignalExternalWorkflow arrives (spec section 20.2; MUST-match
# sdk-python cancel_signal_workflow). $seq is the seq of the
# SignalExternalWorkflowExecution being cancelled. Telling core to drop the
# in-flight signal send; the original Future still settles on the eventual
# Resolve* job (there is no pre-emptive raise).
sub cancel_signal_workflow ($seq) {
    return _command_class()->new({
        cancel_signal_workflow => { seq => $seq },
    });
}

# update_response { protocol_instance_id, accepted|rejected|completed } —
# answers a DoUpdate job (spec section 19.2; MUST-match the UpdateResponse proto,
# workflow_commands.proto:341-355). An accepted update emits two of these (one
# `accepted` then one `completed`/`rejected`, possibly across activations); a
# pre-acceptance rejection emits a single `rejected`. Exactly one of the three
# response arms is set: `accepted` is a google.protobuf.Empty, `rejected`
# carries an already-converted temporal.api.failure.v1.Failure, `completed`
# carries the result temporal.api.common.v1.Payload (or undef for a void return).
sub update_response ($protocol_instance_id, %parts) {
    my %variant;
    if (exists $parts{accepted}) {
        $variant{accepted} = {};   # google.protobuf.Empty
    }
    elsif (exists $parts{rejected}) {
        $variant{rejected} = $parts{rejected};
    }
    else {
        # completed: the handler's result payload. The runner always passes a
        # converted Payload here (the payload converter yields one even for a
        # void/undef handler return), so the `completed` oneof arm is selected.
        $variant{completed} = $parts{completed};
    }
    return _command_class()->new({
        update_response => {
            protocol_instance_id => $protocol_instance_id,
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

=encoding utf8

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

=item C<request_cancel_activity($seq)>

C<RequestCancelActivity { seq }> — emitted when a scheduled activity's
L<Temporalio::Workflow::Future> is cancelled (e.g. by a C<CancelWorkflow> job
propagating down the cancellation tree). C<$seq> is the seq of the
C<ScheduleActivity> being cancelled. Core forwards the request to the running
activity according to the activity's C<ActivityCancellationType>; an
C<abandon>-typed activity never emits this command (the workflow stops waiting
without asking core to cancel the activity).

=item C<start_child_workflow_execution($fields)>

C<StartChildWorkflowExecution { ... }> — emitted when the workflow body calls
C<Temporalio::Workflow::execute_child_workflow> / C<start_child_workflow>
(spec section 18). C<$fields> is the assembled field hashref (the runner owns
seq allocation, payload conversion, the default id/task queue, and the enum
string-to-number mapping).

=item C<cancel_child_workflow_execution($seq, $reason)>

C<CancelChildWorkflowExecution { child_workflow_seq, reason }> — emitted when a
C<Temporalio::Workflow::ChildWorkflowHandle> is cancelled. C<$seq> is the seq of
the C<StartChildWorkflowExecution> being cancelled; an C<abandon>-typed child
never emits this command.

=item C<signal_external_workflow_execution($fields)>

C<SignalExternalWorkflowExecution { ... }> — emitted when a
C<ChildWorkflowHandle>'s C<< ->signal >> (spec section 18) or an
C<ExternalWorkflowHandle>'s C<< ->signal >> (spec section 20) is called.
C<$fields> sets the C<child_workflow_id> oneof arm for a child-targeted signal,
or the C<workflow_execution> arm (a C<NamespacedWorkflowExecution>) for an
external-handle signal.

=item C<request_cancel_external_workflow_execution($fields)>

C<RequestCancelExternalWorkflowExecution { seq, workflow_execution, reason }> —
emitted when an C<ExternalWorkflowHandle>'s C<< ->cancel >> is called (spec
section 20). C<$fields> sets the C<workflow_execution> arm (a
C<NamespacedWorkflowExecution>); the runner owns external-cancel seq allocation
and namespace injection.

=item C<cancel_signal_workflow($seq)>

C<CancelSignalWorkflow { seq }> — emitted when an in-flight
C<SignalExternalWorkflowExecution>'s awaiting frame is cancelled before its
C<ResolveSignalExternalWorkflow> arrives (spec section 20.2). C<$seq> is the seq
of the signal being cancelled.

=item C<respond_to_query($query_id, %parts)>

C<QueryResult { query_id, succeeded|failed }> — answers a C<QueryWorkflow>
activation job. Pass C<< response => $payload >> for a successful query (the
handler's return value converted to a C<temporal.api.common.v1.Payload>, or
omitted for a void return) or C<< failure => $failure >> for a dying handler
(an already-converted C<temporal.api.failure.v1.Failure>). A query failure is
delivered as this command, never as a workflow or task failure.

=item C<update_response($protocol_instance_id, %parts)>

C<UpdateResponse { protocol_instance_id, accepted|rejected|completed }> —
answers a C<DoUpdate> activation job (spec section 19). Pass C<< accepted => 1 >>
for the acceptance phase, C<< rejected => $failure >> for a validator/handler
rejection (an already-converted C<temporal.api.failure.v1.Failure>), or
C<< completed => $payload >> for a successful handler result (a
C<temporal.api.common.v1.Payload>). An accepted update emits two of these (one
C<accepted>, then one C<completed>/C<rejected>); a pre-acceptance rejection emits
a single C<rejected>.

=back

=head1 METHODS

=head2 set_patch_marker

Records a patch marker command for the given patch id (used by C<patched>/C<deprecate_patch>).

=cut
