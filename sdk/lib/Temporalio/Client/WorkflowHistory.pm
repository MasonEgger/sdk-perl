# ABOUTME: A workflow's ID plus its immutable history events (spec R95):
# ABOUTME: from_json/to_json construction for the from-history replayer,
# ABOUTME: MUST-matched to sdk-python client/_workflow.py WorkflowHistory.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use JSON::PP ();
use Scalar::Util ();
use Storable ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Runtime ();

class Temporalio::Client::WorkflowHistory {
    my $HISTORY_TYPE = 'temporal.api.history.v1.History';

    # The workflow's ID. Histories do not embed one, so it rides alongside
    # the events (sdk-python client/_workflow.py:1683).
    field $workflow_id :param;

    # The temporal.api.history.v1.HistoryEvent list, as blessed generated
    # proto instances (the shape a fetch materializes off the wire and
    # from_json reconstructs).
    field $events :param = [];

    method workflow_id { return $workflow_id }
    method events      { return $events }

    # run_id: extracted from the first event's WorkflowExecutionStarted
    # attributes (original_execution_run_id), sdk-python parity
    # (client/_workflow.py:1692-1701). Core's replayer requires this field,
    # so a history that fails here would not replay either.
    method run_id {
        Temporalio::Exception::Runtime->throw(
            message => 'run_id: history has no events')
            unless $events && $events->@*;
        my $first = $events->[0];
        my $attrs =
            Scalar::Util::blessed($first)
            ? $first->workflow_execution_started_event_attributes
            : $first->{workflow_execution_started_event_attributes};
        Temporalio::Exception::Runtime->throw(
            message => 'run_id: first event is not WorkflowExecutionStarted')
            unless defined $attrs;
        return Scalar::Util::blessed($attrs)
            ? $attrs->original_execution_run_id
            : $attrs->{original_execution_run_id};
    }

    # from_json($workflow_id, $history) -> a WorkflowHistory reconstructed
    # from a JSON dump of history: either a JSON string or an already-parsed
    # hashref. Built to accept both the Temporal UI/CLI export forms and
    # to_json output (sdk-python client/_workflow.py:1704 +
    # client/_helpers.py:43 _history_from_json): a fix pass rewrites the
    # legacy pascal-case enum values ("WorkflowExecutionStarted") into the
    # canonical prefixed names before the proto3 JSON decode.
    sub from_json ($class, $workflow_id, $history) {
        my $parsed;
        if (ref $history) {
            Temporalio::Exception::Argument->throw(
                message => 'from_json: JSON history is not a dictionary')
                unless ref $history eq 'HASH';
            # Copy so the fix pass never mutates the caller's structure
            # (Python deep-copies its dict arm the same way).
            $parsed = Storable::dclone($history);
        }
        else {
            my $codec = JSON::PP->new;
            $codec->utf8(1) unless utf8::is_utf8($history);
            $parsed = eval { $codec->decode($history) };
            if ($@) {
                my $detail = "$@";
                chomp $detail;
                Temporalio::Exception::Argument->throw(
                    message => "from_json: invalid JSON: $detail");
            }
            Temporalio::Exception::Argument->throw(
                message => 'from_json: JSON history is not a dictionary')
                unless ref $parsed eq 'HASH';
        }

        my $raw_events = $parsed->{events};
        Temporalio::Exception::Argument->throw(message =>
                "from_json: history does not have iterable 'events'")
            unless ref $raw_events eq 'ARRAY';
        for my $event (@$raw_events) {
            Temporalio::Exception::Argument->throw(
                message => 'from_json: event is not a dictionary')
                unless ref $event eq 'HASH';
            _fix_event_enums($event);
        }

        # Decode through the shared lenient proto3 JSON codec (camelCase or
        # snake_case keys, enum names or numbers, unknown fields ignored —
        # Python's ParseDict(ignore_unknown_fields=True) analog), then
        # materialize the fully-blessed History via the wire round trip
        # (lessons.md 2026-06-13: ->new leaves nested messages unblessed).
        my $values = eval {
            Temporalio::Core::Proto::json()
                ->decode($HISTORY_TYPE, JSON::PP->new->encode($parsed));
        };
        if ($@) {
            my $detail = "$@";
            chomp $detail;
            Temporalio::Exception::Argument->throw(message =>
                "from_json: history does not decode as $HISTORY_TYPE: "
                . $detail);
        }
        my $proto_class = Temporalio::Core::Proto::resolve($HISTORY_TYPE);
        my $history_proto =
            $proto_class->decode($proto_class->new($values)->encode);

        return $class->new(
            workflow_id => $workflow_id,
            events      => $history_proto->events // [],
        );
    }

    # to_json() -> the canonical proto3 JSON document for this history's
    # events (sdk-python client/_workflow.py:1721 to_json). The workflow ID
    # is NOT included, matching Python.
    method to_json {
        my $proto_class = Temporalio::Core::Proto::resolve($HISTORY_TYPE);
        return Temporalio::Core::Proto::json()->encode($HISTORY_TYPE,
            $proto_class->new({ events => $events })->to_hashref);
    }

    # The legacy-export fix pass for one event, ported field-for-field from
    # sdk-python client/_helpers.py _history_from_json (:58-105). Old
    # UI/tctl exports carry enums as unprefixed pascal case
    # ("WorkflowExecutionStarted", "Normal"); the canonical decode needs the
    # prefixed names ("EVENT_TYPE_WORKFLOW_EXECUTION_STARTED"). Keys are the
    # camelCase JSON names, as in the Python source; the proto3 decode is
    # lenient about the rest.
    sub _fix_event_enums ($event) {
        _fix_history_enum(
            'CANCEL_EXTERNAL_WORKFLOW_EXECUTION_FAILED_CAUSE', $event,
            'requestCancelExternalWorkflowExecutionFailedEventAttributes',
            'cause');
        _fix_history_enum('CONTINUE_AS_NEW_INITIATOR', $event,
            '*', 'initiator');
        _fix_history_enum('EVENT_TYPE', $event, 'eventType');
        _fix_history_enum('PARENT_CLOSE_POLICY', $event,
            'startChildWorkflowExecutionInitiatedEventAttributes',
            'parentClosePolicy');
        _fix_history_enum('RETRY_STATE', $event, '*', 'retryState');
        _fix_history_enum(
            'SIGNAL_EXTERNAL_WORKFLOW_EXECUTION_FAILED_CAUSE', $event,
            'signalExternalWorkflowExecutionFailedEventAttributes', 'cause');
        _fix_history_enum(
            'START_CHILD_WORKFLOW_EXECUTION_FAILED_CAUSE', $event,
            'startChildWorkflowExecutionFailedEventAttributes', 'cause');
        _fix_history_enum('TASK_QUEUE_KIND', $event, '*', 'taskQueue',
            'kind');
        _fix_history_enum('TIMEOUT_TYPE', $event,
            'workflowTaskTimedOutEventAttributes', 'timeoutType');
        _fix_history_enum('WORKFLOW_ID_REUSE_POLICY', $event,
            'startChildWorkflowExecutionInitiatedEventAttributes',
            'workflowIdReusePolicy');
        _fix_history_enum('WORKFLOW_TASK_FAILED_CAUSE', $event,
            'workflowTaskFailedEventAttributes', 'cause');
        _fix_history_failure($event, '*', 'failure');
        _fix_history_failure($event, 'activityTaskStartedEventAttributes',
            'lastFailure');
        _fix_history_failure($event,
            'workflowExecutionStartedEventAttributes', 'continuedFailure');
        return;
    }

    # Walk $parent along @attrs ('*' fans out over every hash child) and
    # rewrite an unprefixed pascal-case enum value at the leaf into
    # $prefix . '_UPPER_SNAKE' (Python _fix_history_enum). Numbers and
    # already-prefixed canonical names pass through untouched.
    sub _fix_history_enum ($prefix, $parent, @attrs) {
        my ($attr, @rest) = @attrs;
        if ($attr eq '*') {
            for my $child (values %$parent) {
                _fix_history_enum($prefix, $child, @rest)
                    if ref $child eq 'HASH';
            }
            return;
        }
        my $child = $parent->{$attr};
        if (!@rest) {
            return unless defined $child && !ref $child;
            return unless $child =~ /^[A-Za-z]/;   # JSON numbers stay as-is
            return if index($child, $prefix) == 0; # already canonical
            my $snaked = $child =~ s/([A-Z]+)/_$1/gr;
            $parent->{$attr} = $prefix . uc $snaked;
        }
        elsif (ref $child eq 'HASH') {
            _fix_history_enum($prefix, $child, @rest);
        }
        elsif (ref $child eq 'ARRAY') {
            for my $item (@$child) {
                _fix_history_enum($prefix, $item, @rest)
                    if ref $item eq 'HASH';
            }
        }
        return;
    }

    # Fix the enum fields inside a Failure at $parent->@attrs, then recurse
    # through the whole cause chain (Python _fix_history_failure).
    sub _fix_history_failure ($parent, @attrs) {
        _fix_history_enum('TIMEOUT_TYPE', $parent, @attrs,
            'timeoutFailureInfo', 'timeoutType');
        _fix_history_enum('RETRY_STATE', $parent, @attrs, '*', 'retryState');
        my @parents = ($parent);
        for my $attr (@attrs) {
            my @next;
            for my $node (@parents) {
                if ($attr eq '*') {
                    push @next, grep { ref $_ eq 'HASH' } values %$node;
                }
                else {
                    my $child = $node->{$attr};
                    push @next, $child if ref $child eq 'HASH';
                }
            }
            return unless @next;
            @parents = @next;
        }
        _fix_history_failure($_, 'cause') for @parents;
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::WorkflowHistory - a workflow's ID and immutable history

=head1 SYNOPSIS

    use Temporalio::Client::WorkflowHistory;

    # From a JSON dump downloaded via the Temporal CLI or web UI:
    my $history = Temporalio::Client::WorkflowHistory->from_json(
        'my-workflow-id', $json_text);

    # From fetched events (e.g. collected via fetch_history_events):
    my $fetched = Temporalio::Client::WorkflowHistory->new(
        workflow_id => 'my-workflow-id',
        events      => \@history_events,
    );

    say $history->run_id;
    my $json = $history->to_json;

=head1 DESCRIPTION

A workflow's ID plus its immutable C<temporal.api.history.v1.HistoryEvent>
list (spec R95; sdk-python C<client/_workflow.py> C<WorkflowHistory>
parity). This is the input type for the from-history replayer,
L<Temporalio::Test::WorkflowReplay>'s C<replay_workflow> and
C<replay_workflows>.

C<from_json> accepts both the canonical proto3 JSON form C<to_json>
produces and the Temporal UI/CLI export forms: a fix pass rewrites the
legacy unprefixed pascal-case enum values (for example
C<WorkflowExecutionStarted>) into the canonical prefixed names before
decoding, matching sdk-python's C<_history_from_json> helper.

=head1 CONSTRUCTOR

=head2 new

    my $history = Temporalio::Client::WorkflowHistory->new(
        workflow_id => $id,
        events      => \@events,
    );

C<workflow_id> is required; histories do not embed one. C<events>
(optional, default C<[]>) is the blessed C<HistoryEvent> proto list, in
event-id order.

=head1 METHODS

=head2 workflow_id

The workflow's ID.

=head2 events

The C<temporal.api.history.v1.HistoryEvent> list.

=head2 run_id

The run ID extracted from the first event's C<WorkflowExecutionStarted>
attributes (C<original_execution_run_id>). Raises
L<Temporalio::Exception::Runtime> when the history has no events or the
first event is not the workflow start.

=head2 from_json

    my $history = Temporalio::Client::WorkflowHistory->from_json(
        $workflow_id, $json_text_or_hashref);

Class method. Reconstructs a history from a JSON dump: either a JSON
string or an already-parsed hashref (which is copied, never mutated).
Raises L<Temporalio::Exception::Argument> on malformed JSON, a
non-object document, missing or non-array C<events>, or a document that
does not decode as C<temporal.api.history.v1.History>.

=head2 to_json

The canonical proto3 JSON document for this history's events. The
workflow ID is not included, matching sdk-python.

=cut
