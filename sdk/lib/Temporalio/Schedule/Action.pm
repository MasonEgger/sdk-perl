# ABOUTME: Schedule action (spec section 25). Action::StartWorkflow wraps a
# ABOUTME: NewWorkflowExecutionInfo; _to_proto is async (encodes payloads).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Scalar::Util ();
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

    # When constructed from a describe response, the args are raw Payloads kept
    # verbatim so describe->modify->update re-emits identical bytes.
    field $_raw_input        :param = undef;

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

        $info{workflow_execution_timeout} = _duration($execution_timeout)
            if defined $execution_timeout;
        $info{workflow_run_timeout} = _duration($run_timeout)
            if defined $run_timeout;
        $info{workflow_task_timeout} = _duration($task_timeout)
            if defined $task_timeout;
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

        my $NewInfo = Temporalio::Core::Proto::resolve(
            'temporal.api.workflow.v1.NewWorkflowExecutionInfo');
        my $Action = Temporalio::Core::Proto::resolve(
            'temporal.api.schedule.v1.ScheduleAction');
        return $Action->new({ start_workflow => $NewInfo->new(\%info) });
    }

    # _from_proto($info) — class method; keep the input Payloads raw.
    sub _from_proto ($class, $info) {
        return $class->new(
            workflow   => $info->workflow_type ? $info->workflow_type->name : '',
            id         => $info->workflow_id // '',
            task_queue => $info->task_queue ? $info->task_queue->name : '',
            _raw_input => $info->input,
        );
    }

    sub _duration ($seconds) {
        my $Duration = Temporalio::Core::Proto::resolve('google.protobuf.Duration');
        my $whole = int($seconds);
        my $nanos = int(($seconds - $whole) * 1_000_000_000 + 0.5);
        return $Duration->new({ seconds => $whole, nanos => $nanos });
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

=head1 CONSTRUCTOR

=head2 new

    my $a = Temporalio::Schedule::Action::StartWorkflow->new(%fields);

Named parameters: C<workflow> (required, type-name string), C<id> (required),
C<task_queue> (required), C<args>, C<execution_timeout>, C<run_timeout>,
C<task_timeout> (seconds), C<retry_policy>, C<memo>, C<search_attributes>,
C<headers>, C<priority>.

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

Accessor returning the memo hashref.

=head2 search_attributes

Accessor returning the typed search attributes.

=head2 headers

Accessor returning the headers hashref.

=head2 priority

Accessor returning the priority.

=cut
