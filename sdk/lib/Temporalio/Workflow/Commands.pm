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

# schedule_local_activity { ... } — emitted when the workflow body calls
# Temporalio::Workflow::execute_local_activity / start_local_activity (spec
# section 21). $fields is the already-assembled ScheduleLocalActivity field
# hashref (seq, activity_id, activity_type, headers, arguments, the three
# timeout Durations, retry_policy, local_retry_threshold Duration,
# cancellation_type, and — only on a backoff re-schedule — attempt and
# original_schedule_time). The runner owns seq allocation, timeout/threshold
# conversion, the default activity_id, and the enum string -> number mapping.
# An optional $summary_payload (a temporal.api.common.v1.Payload) is placed on
# the command's user_metadata.summary (spec section 21.2). The LA command has NO
# task_queue / heartbeat_timeout / priority (core runs it in-process).
sub schedule_local_activity ($fields, $summary_payload = undef) {
    return _command_class()->new({
        schedule_local_activity => $fields,
        (defined $summary_payload
            ? (user_metadata => { summary => $summary_payload }) : ()),
    });
}

# request_cancel_local_activity { seq } — emitted when a scheduled local
# activity's Workflow::Future is cancelled under try_cancel /
# wait_cancellation_completed (spec section 21.2; MUST-match the
# RequestCancelLocalActivity proto, keyed on the ScheduleLocalActivity seq).
# ABANDON-typed LAs never emit this (the workflow stops waiting without asking
# core to cancel — see Temporalio::Workflow::Runner's LA cancel hook).
sub request_cancel_local_activity ($seq) {
    return _command_class()->new({
        request_cancel_local_activity => { seq => $seq },
    });
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

# upsert_workflow_search_attributes { search_attributes } — emitted when the
# workflow body calls Temporalio::Workflow::upsert_search_attributes (spec
# section 24, oneof tag 18; MUST-match sdk-python
# command.upsert_workflow_search_attributes.search_attributes). $search_attributes
# is an already-built temporal.api.common.v1.SearchAttributes proto whose
# indexed_fields map has one Payload per updated key (a set carries the typed SA
# metadata; an unset carries a proper null Payload — the runner owns the
# conversion). Core/the server merges the map into the existing attributes, these
# values winning.
sub upsert_workflow_search_attributes ($search_attributes) {
    return _command_class()->new({
        upsert_workflow_search_attributes => {
            search_attributes => $search_attributes,
        },
    });
}

# modify_workflow_properties { upserted_memo } — emitted when the workflow body
# calls Temporalio::Workflow::upsert_memo (spec section 24, oneof tag 19;
# MUST-match sdk-python command.modify_workflow_properties.upserted_memo). $memo
# is an already-built temporal.api.common.v1.Memo proto whose fields map has one
# Payload per key (an undef value is encoded as an empty/null Payload — the
# server-side deletion convention; the runner owns the conversion). The server
# merges the map into the existing memo.
sub modify_workflow_properties ($memo) {
    return _command_class()->new({
        modify_workflow_properties => { upserted_memo => $memo },
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

# schedule_nexus_operation { ... } — emitted when the workflow body calls a
# NexusClient's start_operation / execute_operation (spec section 26.1, oneof arm
# 21; MUST-match the ScheduleNexusOperation proto, workflow_commands.proto:358).
# $fields is the already-assembled field hashref: seq, endpoint, service,
# operation, the SINGLE `input` Payload (the proto carries one input, not a
# repeated list), the three timeout Durations (schedule_to_close_timeout,
# schedule_to_start_timeout, start_to_close_timeout), nexus_header (a plain
# string -> string map, NOT Temporal-header Payloads), and cancellation_type (the
# NexusOperationCancellationType enum number). An optional $summary_payload (a
# temporal.api.common.v1.Payload) is placed on the WorkflowCommand
# user_metadata.summary (spec section 26.1; matching the timer / local-activity
# summary convention — ScheduleNexusOperation itself has no user_metadata field).
# The runner owns nexus-seq allocation, payload conversion, timeout/enum mapping.
sub schedule_nexus_operation ($fields, $summary_payload = undef) {
    return _command_class()->new({
        schedule_nexus_operation => $fields,
        (defined $summary_payload
            ? (user_metadata => { summary => $summary_payload }) : ()),
    });
}

# request_cancel_nexus_operation { seq } — emitted when a NexusOperationHandle's
# ->cancel is called (or a whole-workflow CancelWorkflow propagates), spec
# section 26.3, oneof arm 22; MUST-match the RequestCancelNexusOperation proto
# (workflow_commands.proto:401, keyed on the ScheduleNexusOperation seq). An
# ABANDON-typed operation never emits this command (the workflow stops waiting
# without asking core to cancel — see the runner's nexus cancel hook).
sub request_cancel_nexus_operation ($seq) {
    return _command_class()->new({
        request_cancel_nexus_operation => { seq => $seq },
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

=item C<schedule_local_activity($fields, $summary_payload)>

C<ScheduleLocalActivity { ... }> — emitted when the workflow body calls
C<Temporalio::Workflow::execute_local_activity> / C<start_local_activity> (spec
section 21). C<$fields> is the assembled C<ScheduleLocalActivity> field hashref
(C<seq>, C<activity_id>, C<activity_type>, C<headers>, C<arguments>, the three
timeout Durations, C<retry_policy>, C<local_retry_threshold> Duration,
C<cancellation_type>, and on a backoff re-schedule C<attempt> /
C<original_schedule_time>). The optional C<$summary_payload> (a
C<temporal.api.common.v1.Payload>) is placed on the command's
C<user_metadata.summary>. The LA command has no C<task_queue> /
C<heartbeat_timeout> / C<priority> (core runs it in-process).

=item C<request_cancel_local_activity($seq)>

C<RequestCancelLocalActivity { seq }> — emitted when a scheduled local
activity's L<Temporalio::Workflow::Future> is cancelled under C<try_cancel> /
C<wait_cancellation_completed>. C<$seq> is the seq of the
C<ScheduleLocalActivity> being cancelled; an C<abandon>-typed LA never emits
this command.

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

=item C<upsert_workflow_search_attributes($search_attributes)>

C<UpsertWorkflowSearchAttributes { search_attributes }> (spec section 24, oneof
tag 18) — emitted when the workflow body calls
C<Temporalio::Workflow::upsert_search_attributes>. C<$search_attributes> is a
built C<temporal.api.common.v1.SearchAttributes> proto whose C<indexed_fields>
map carries one Payload per updated key (a set carries the typed SA metadata; an
unset carries a proper null Payload). The runner owns the conversion.

=item C<modify_workflow_properties($memo)>

C<ModifyWorkflowProperties { upserted_memo }> (spec section 24, oneof tag 19) —
emitted when the workflow body calls C<Temporalio::Workflow::upsert_memo>.
C<$memo> is a built C<temporal.api.common.v1.Memo> proto whose C<fields> map
carries one Payload per key (an C<undef> value encodes an empty/null Payload, the
deletion convention). The runner owns the conversion.

=item C<schedule_nexus_operation($fields, $summary_payload)>

C<ScheduleNexusOperation { ... }> (spec section 26.1, oneof arm 21) — emitted
when the workflow body calls a Nexus client's C<start_operation> /
C<execute_operation>. C<$fields> is the assembled field hashref (C<seq>,
C<endpoint>, C<service>, C<operation>, the SINGLE C<input> Payload, the three
timeout Durations, C<nexus_header> string map, C<cancellation_type> enum number).
The optional C<$summary_payload> (a C<temporal.api.common.v1.Payload>) is placed
on the C<WorkflowCommand> C<user_metadata.summary> (the proto message itself has
no summary field). The runner owns nexus-seq allocation and all conversion.

=item C<request_cancel_nexus_operation($seq)>

C<RequestCancelNexusOperation { seq }> (spec section 26.3, oneof arm 22) —
emitted when a C<Temporalio::Workflow::NexusOperationHandle>'s C<< ->cancel >> is
called (or a whole-workflow C<CancelWorkflow> propagates). C<$seq> is the seq of
the C<ScheduleNexusOperation> being cancelled; an C<abandon>-typed operation
never emits this command.

=back

=head1 METHODS

=head2 set_patch_marker

Records a patch marker command for the given patch id (used by C<patched>/C<deprecate_patch>).

=cut
