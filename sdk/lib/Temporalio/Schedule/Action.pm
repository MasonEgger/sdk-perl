# ABOUTME: Schedule action (spec section 25). Action::StartWorkflow wraps a
# ABOUTME: NewWorkflowExecutionInfo; _to_proto is async (encodes payloads).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Common::Priority ();
use Temporalio::Common::RetryPolicy ();
use Temporalio::Common::TypedSearchAttributes ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();

# Base class is abstract; the only concrete subclass is StartWorkflow.
class Temporalio::Schedule::Action {
    # _from_proto($action) — class method; dispatch on the populated oneof.
    sub _from_proto ($class, $action) {
        my $sw = $action->start_workflow;
        return Temporalio::Schedule::Action::StartWorkflow->_from_proto($sw)
            if defined $sw;
        Temporalio::Exception::Argument->throw(
            message => 'unsupported schedule action (no start_workflow)');
    }
}

class Temporalio::Schedule::Action::StartWorkflow
    :isa(Temporalio::Schedule::Action) {

    field $workflow          :param = undef;     # workflow TYPE-NAME string
    field $args              :param = undef;     # arrayref (values OR Payloads)
    field $id                :param = undef;
    field $task_queue        :param = undef;
    field $execution_timeout :param = undef;
    field $run_timeout       :param = undef;
    field $task_timeout      :param = undef;
    field $retry_policy      :param = undef;
    field $memo              :param = undef;
    field $search_attributes :param = undef;
    field $headers           :param = undef;
    field $priority          :param = undef;
    field $static_summary    :param = undef;     # string or pre-encoded Payload
    field $static_details    :param = undef;     # string or pre-encoded Payload

    # When constructed from a describe response, the args are raw Payloads kept
    # verbatim so describe->modify->update re-emits identical bytes.
    field $_raw_input        :param = undef;

    # Workflow/run/task timeout: identical seconds<->Duration shape in both
    # directions, so both _to_proto and _from_proto iterate this one
    # (accessor field name => proto field name) list rather than repeating the
    # same pattern three times each (spec I4 / GitHub issue #4 REFACTOR step).
    my @DURATION_FIELDS = (
        [ execution_timeout => 'workflow_execution_timeout' ],
        [ run_timeout       => 'workflow_run_timeout' ],
        [ task_timeout      => 'workflow_task_timeout' ],
    );

    ADJUST {
        $args //= [];
        Temporalio::Exception::Argument->throw(
            message => 'schedule action requires a workflow type name (string)')
            unless defined $workflow && !ref $workflow && length $workflow;
        Temporalio::Exception::Argument->throw(
            message => 'schedule action requires an id')
            unless defined $id && length $id;
        Temporalio::Exception::Argument->throw(
            message => 'schedule action requires a task_queue')
            unless defined $task_queue && length $task_queue;
    }

    method workflow          { $workflow }
    method args              { $args }
    method id                { $id }
    method task_queue        { $task_queue }
    method execution_timeout { $execution_timeout }
    method run_timeout       { $run_timeout }
    method task_timeout      { $task_timeout }
    method retry_policy      { $retry_policy }
    method memo              { $memo }
    method search_attributes { $search_attributes }
    method headers           { $headers }
    method priority          { $priority }
    method static_summary    { $static_summary }
    method static_details    { $static_details }

    # _to_proto($client) — async; encodes args/memo/headers/SAs through the
    # client's data converter and builds a ScheduleAction{start_workflow}.
    async method _to_proto ($client) {
        my $WorkflowType = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.WorkflowType');
        my $TaskQueue = Temporalio::Core::Proto::resolve(
            'temporal.api.taskqueue.v1.TaskQueue');

        my %info = (
            workflow_id   => $id,
            workflow_type => $WorkflowType->new({ name => $workflow }),
            task_queue    => $TaskQueue->new({ name => $task_queue }),
        );

        # Input: a raw Payloads message round-trips verbatim; otherwise encode
        # each arg (an already-Payload arg passes through the converter).
        if (defined $_raw_input) {
            $info{input} = $_raw_input;
        }
        elsif (@$args) {
            my @payloads = await $client->data_converter->to_payloads($args);
            my $Payloads = Temporalio::Core::Proto::resolve(
                'temporal.api.common.v1.Payloads');
            $info{input} = $Payloads->new({ payloads => [@payloads] });
        }

        my %timeout_field_value = (
            execution_timeout => $execution_timeout,
            run_timeout       => $run_timeout,
            task_timeout      => $task_timeout,
        );
        for my $pair (@DURATION_FIELDS) {
            my ($field, $proto_field) = @$pair;
            my $seconds = $timeout_field_value{$field};
            $info{$proto_field} = _duration($seconds) if defined $seconds;
        }
        $info{retry_policy} = $retry_policy->to_proto if defined $retry_policy;
        $info{priority}     = $priority->to_proto if defined $priority;

        if (defined $memo) {
            $info{memo} = await $client->_encode_string_payload_map(
                'temporal.api.common.v1.Memo', $memo);
        }
        if (defined $headers) {
            $info{header} = await $client->_encode_string_payload_map(
                'temporal.api.common.v1.Header', $headers);
        }
        if (defined $search_attributes) {
            $info{search_attributes} =
                Temporalio::Client::_coerce_search_attributes($search_attributes);
        }

        # static_summary/static_details -> NewWorkflowExecutionInfo
        # user_metadata (parity audit, schedule/runtime finding 1): reuse the
        # shared R37 converter builder rather than a schedule-local copy, so
        # a string encodes to a single Payload and a pre-encoded Payload
        # passes through untouched. MUST-match sdk-python
        # client/_schedule.py:551-552 (_to_proto's _encode_user_metadata).
        if (defined $static_summary || defined $static_details) {
            $info{user_metadata} = await $client->data_converter
                ->encode_user_metadata($static_summary, $static_details);
        }

        my $NewInfo = Temporalio::Core::Proto::resolve(
            'temporal.api.workflow.v1.NewWorkflowExecutionInfo');
        my $Action = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.ScheduleAction');
        return $Action->new({ start_workflow => $NewInfo->new(\%info) });
    }

    # _from_proto($info): class method; keep the input Payloads raw, and
    # likewise memo/headers/static_summary/static_details decode to raw
    # pass-through Payloads/Payload maps rather than through the data
    # converter (this is a sync class method with no client to convert with,
    # the args contract already established for _raw_input). MUST-match
    # sdk-python client/_schedule.py ScheduleActionStartWorkflow.__init__'s
    # raw_info branch (~:684-744): every field _to_proto writes decodes back
    # here (spec I4 / GitHub issue #4, closing the R82 encode-only gap from
    # commit 8d37317).
    sub _from_proto ($class, $info) {
        my %args = (
            workflow   => $info->workflow_type ? $info->workflow_type->name : '',
            id         => $info->workflow_id // '',
            task_queue => $info->task_queue ? $info->task_queue->name : '',
            _raw_input => $info->input,
        );

        for my $pair (@DURATION_FIELDS) {
            my ($field, $proto_field) = @$pair;
            my $duration = $info->$proto_field;
            $args{$field} = _duration_to_seconds($duration) if defined $duration;
        }

        if (defined(my $retry_policy = $info->retry_policy)) {
            $args{retry_policy} =
                Temporalio::Common::RetryPolicy->_from_proto($retry_policy);
        }
        if (defined(my $priority = $info->priority)) {
            $args{priority} = Temporalio::Common::Priority->_from_proto($priority);
        }

        if (defined(my $memo = $info->memo)) {
            my $fields = $memo->fields // {};
            $args{memo} = { %$fields } if %$fields;
        }
        if (defined(my $header = $info->header)) {
            my $fields = $header->fields // {};
            $args{headers} = { %$fields } if %$fields;
        }
        if (defined(my $sa = $info->search_attributes)) {
            my $decoded =
                Temporalio::Common::TypedSearchAttributes->_from_proto($sa);
            $args{search_attributes} = $decoded if @{ $decoded->pairs };
        }

        # user_metadata -> static_summary/static_details, each a raw
        # pass-through Payload (mirrors sdk-python raw_info.user_metadata.summary
        # / .details, ~:730-739).
        if (defined(my $user_metadata = $info->user_metadata)) {
            $args{static_summary} = $user_metadata->summary
                if defined $user_metadata->summary;
            $args{static_details} = $user_metadata->details
                if defined $user_metadata->details;
        }

        return $class->new(%args);
    }

    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve('google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
    }

    sub _duration_to_seconds ($duration) {
        return undef unless defined $duration;
        return ($duration->seconds // 0) + ($duration->nanos // 0) / 1_000_000_000;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Schedule::Action - what a schedule does when it fires

=head1 SYNOPSIS

    my $action = Temporalio::Schedule::Action::StartWorkflow->new(
        workflow   => 'MyWorkflow',
        args       => [ 'arg1' ],
        id         => 'sched-wf',
        task_queue => 'tq',
    );

=head1 DESCRIPTION

A schedule action (spec section 25). The only concrete action is
L<Temporalio::Schedule::Action::StartWorkflow>, which wraps a
C<temporal.api.workflow.v1.NewWorkflowExecutionInfo>. The action takes a
workflow B<type-name string> only; passing C<workflow_id_reuse_policy> or
C<cron_schedule> is an unknown-kwarg error (the schedule owns its own overlap
and spec).

C<_to_proto($client)> is async because it encodes args, memo, headers, and
search attributes through the client's data converter. An arg that is already a
C<Payload> passes through unchanged. When the action was decoded from a describe
response the input is held as raw Payloads so a describe-modify-update round
trip re-emits identical bytes.

C<_from_proto> (the class method a describe response builds an action through)
decodes every field C<_to_proto> writes: C<workflow>/C<id>/C<task_queue>/C<args>
(args stay raw C<Payloads>, per above), C<execution_timeout>/C<run_timeout>/
C<task_timeout> (seconds), C<retry_policy>
(a L<Temporalio::Common::RetryPolicy>), C<priority> (a
L<Temporalio::Common::Priority>), C<search_attributes> (a
L<Temporalio::Common::TypedSearchAttributes>), and C<memo>/C<headers>/
C<static_summary>/C<static_details> (each a raw pass-through C<Payload> or a
C<{ name => Payload }> map, since this is a synchronous class method with no
data converter to decode through). A describe-modify-update cycle that rebuilds a
new action from a decoded one's accessors therefore carries every field
forward instead of silently dropping it (spec I4 / GitHub issue #4).

=head1 CONSTRUCTOR

=head2 new

    my $a = Temporalio::Schedule::Action::StartWorkflow->new(%fields);

Named parameters: C<workflow> (required, type-name string), C<id> (required),
C<task_queue> (required), C<args>, C<execution_timeout>, C<run_timeout>,
C<task_timeout> (seconds), C<retry_policy>, C<memo>, C<search_attributes>,
C<headers>, C<priority>, C<static_summary>, C<static_details>.

C<static_summary> and C<static_details> (each a string or a pre-encoded
C<Payload>) become the started workflow's fixed summary/details: they encode
into C<NewWorkflowExecutionInfo.user_metadata> exactly as they do on a direct
C<start_workflow> call.

=head1 METHODS

=head2 workflow

Accessor returning the workflow type name.

=head2 args

Accessor returning the workflow argument list.

=head2 id

Accessor returning the workflow id.

=head2 task_queue

Accessor returning the task queue.

=head2 execution_timeout

Accessor returning the execution timeout in seconds.

=head2 run_timeout

Accessor returning the run timeout in seconds.

=head2 task_timeout

Accessor returning the task timeout in seconds.

=head2 retry_policy

Accessor returning the retry policy.

=head2 memo

Accessor returning the memo hashref. When the action was constructed directly
the values are whatever the caller passed; when decoded from a describe
response (C<_from_proto>) each value is a raw pass-through C<Payload>.

=head2 search_attributes

Accessor returning the typed search attributes (a
L<Temporalio::Common::TypedSearchAttributes>, including when decoded from a
describe response).

=head2 headers

Accessor returning the headers hashref. Same raw-C<Payload>-on-decode
convention as C<memo>.

=head2 priority

Accessor returning the priority (a L<Temporalio::Common::Priority>, including
when decoded from a describe response).

=head2 static_summary

Accessor returning the fixed single-line workflow summary (string or Payload
when set directly; always a raw pass-through C<Payload> when decoded from a
describe response).

=head2 static_details

Accessor returning the fixed workflow details (string or Payload when set
directly; always a raw pass-through C<Payload> when decoded from a describe
response).

=cut
