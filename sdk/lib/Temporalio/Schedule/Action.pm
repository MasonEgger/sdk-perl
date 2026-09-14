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

    # Every indexed search-attribute field the decode could not type, held as
    # the verbatim Payload the server sent. The leading underscore marks the
    # constructor key as an internal channel for _from_proto (the same
    # convention as $_raw_input), not public API: spec section 7.4 forbids
    # untyped search-attribute INPUT, so the ADJUST block below accepts only
    # the Payload objects a decode produces. Re-emitted unchanged by _to_proto
    # so a describe-modify-update cycle does not strip the field.
    field $_untyped_search_attributes :param = undef;

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

        # The untyped residual is wire-sourced: every value has to be the
        # Payload the server sent. Without this, the private constructor key
        # would be a back door around the spec section 7.4 ban on untyped
        # search-attribute input, since _to_proto re-sends the residual
        # verbatim and never looks at what is in it.
        if (defined $_untyped_search_attributes) {
            Temporalio::Exception::Argument->throw(message =>
                '_untyped_search_attributes must be a hashref of '
                . 'name => Payload')
                unless ref $_untyped_search_attributes eq 'HASH';
            for my $sa_name (sort keys %$_untyped_search_attributes) {
                my $payload = $_untyped_search_attributes->{$sa_name};
                next if Scalar::Util::blessed($payload)
                    && $payload->can('data');
                Temporalio::Exception::Argument->throw(message =>
                    "untyped search attribute '$sa_name' must be the verbatim "
                    . 'Payload the server sent; untyped search-attribute input '
                    . 'is not accepted (spec section 7.4)');
            }
        }
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

    # Read-only view of the wire-sourced untyped residual. The copy is
    # hash-level only: adding or removing a name here cannot change what
    # _to_proto will re-send, but the Payload objects inside are the same ones
    # (they are never mutated on either side of the round trip).
    method untyped_search_attributes {
        return undef unless $_untyped_search_attributes;
        return { %$_untyped_search_attributes };
    }

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
            $info{$proto_field} =
                Temporalio::Core::Proto::duration_from_seconds($seconds)
                if defined $seconds;
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
        if (defined $search_attributes || $_untyped_search_attributes) {
            $info{search_attributes} = $self->_search_attributes_proto;
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

    # The SearchAttributes message this action sends: the typed collection plus
    # every field the decode could not type, re-emitted as the verbatim payload
    # it arrived as. A name in both keeps its typed value, which is the outcome
    # of sdk-python's encode order (client/_schedule.py :838-852 writes the
    # untyped-not-in-typed subset first, then lets the typed set overwrite).
    method _search_attributes_proto {
        my %indexed_fields;
        if (defined $search_attributes) {
            my $typed =
                Temporalio::Client::_coerce_search_attributes($search_attributes);
            %indexed_fields = %{ $typed->indexed_fields // {} };
        }
        for my $name (keys %{ $_untyped_search_attributes // {} }) {
            $indexed_fields{$name} //= $_untyped_search_attributes->{$name};
        }
        my $SearchAttributes = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.SearchAttributes');
        return $SearchAttributes->new({ indexed_fields => \%indexed_fields });
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
            $args{$field} =
                Temporalio::Core::Proto::seconds_from_duration($duration)
                if defined $duration;
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
        # Search attributes decode in one pass into the typed pairs and the
        # residual the SDK could not type. Dropping the residual would make
        # describe-modify-update strip attributes the server holds, which is
        # exactly what sdk-python's untyped_search_attributes exists to prevent
        # (client/_schedule.py :719-729).
        if (defined(my $sa = $info->search_attributes)) {
            my ($pairs, $untyped) =
                Temporalio::Common::TypedSearchAttributes->_decode_fields($sa);
            $args{search_attributes} =
                Temporalio::Common::TypedSearchAttributes->new($pairs) if @$pairs;
            $args{_untyped_search_attributes} = $untyped if %$untyped;
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

    # The seconds<->google.protobuf.Duration conversion pair lives in
    # Temporalio::Core::Proto (I14; formerly local _duration/
    # _duration_to_seconds helpers here).
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

=head2 Search attributes the SDK cannot type

An indexed search-attribute field only decodes into the typed
L<Temporalio::Common::TypedSearchAttributes> collection when its payload
carries a recognized C<type> metadata value B<and> a value of that type's
shape. A field that carries no C<type> metadata (the shape a server that
indexed the attribute before typed search attributes still returns), or a type
this SDK version has no key factory for, or a value that will not decode, is
B<skipped> by the typed decode rather than raising: mirroring sdk-python's
C<decode_typed_search_attributes>, an attribute this SDK does not understand
must never take a whole describe response down.

Skipped fields are not lost. C<_from_proto> keeps each one verbatim (as the
exact C<Payload> the server sent) in an untyped residual, readable through
C<untyped_search_attributes>, and C<_to_proto> re-emits the residual
byte-for-byte alongside the typed collection. A describe-modify-update cycle
therefore leaves such an attribute exactly as it found it instead of deleting
it from the schedule. Where a name appears in both, the typed value wins.

The residual is B<wire-sourced>: C<_from_proto> is its only writer. It travels
on an underscore-prefixed constructor key, which (like C<_raw_input>) is an
internal channel for that decode rather than public API, and which accepts
only the verbatim C<Payload> objects a decode produces: any other value raises
L<Temporalio::Exception::Argument>. Untyped search-attribute B<input> stays
forbidden either way (spec section 7.4: C<search_attributes> must be a
L<Temporalio::Common::TypedSearchAttributes>, and a bare untyped hashref
raises L<Temporalio::Exception::Argument>).

C<untyped_search_attributes> copies the hash, so adding or removing a name in
the returned value does not change what an update will send. The copy is
hash-level only: the C<Payload> objects inside are the same ones the action
holds, and neither side of the round trip mutates them.

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

=head2 untyped_search_attributes

Accessor returning a C<{ name =E<gt> Payload }> hashref of the indexed
search-attribute fields the decode could not type, or C<undef> when there were
none. Read-only and wire-sourced: only C<_from_proto> populates it (see
L</Search attributes the SDK cannot type>), the returned hashref is a shallow
copy, and C<_to_proto> re-sends the held payloads unchanged.

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
