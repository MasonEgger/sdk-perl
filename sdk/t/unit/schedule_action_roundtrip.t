# ABOUTME: Round-trip test for spec I4 (GitHub issue #4): every optional field
# ABOUTME: Schedule::Action::StartWorkflow::_to_proto writes must survive a
# ABOUTME: _to_proto -> _from_proto cycle (describe-modify-update parity).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future::AsyncAwait;

use Temporalio::Client ();
use Temporalio::Common::Priority ();
use Temporalio::Common::RetryPolicy ();
use Temporalio::Common::SearchAttributeKey ();
use Temporalio::Common::TypedSearchAttributes ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();
use Temporalio::Payload ();
use Temporalio::Schedule ();

Temporalio::Core::Proto->load;

# A converter-only client: _to_proto reads data_converter only (never the
# connection), matching the schedule_types.t / schedule_action_user_metadata.t
# harness convention.
sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-roundtrip',
        identity       => 'id-roundtrip@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# ---------------------------------------------------------------------------
# Every optional field populated: _to_proto encode, then _from_proto decode
# on the resulting NewWorkflowExecutionInfo must recover every field.
# Python contract (record file:line): ../sdk-python
# temporalio/client/_schedule.py ScheduleActionStartWorkflow.__init__
# raw_info branch (~:684-744) decodes execution/run/task timeout, retry_policy
# (RetryPolicy.from_proto), memo (raw Payload fields, ~:712), typed
# search_attributes (decode_typed_search_attributes, ~:713-717), headers (raw
# Payload fields, ~:718), static_summary/static_details (raw
# user_metadata.summary/.details Payloads, ~:730-739), and priority
# (Priority._from_proto, ~:740-744), the same field set _to_proto (~:775-860)
# encodes. Confirmed live in the checked-out ../sdk-python tree.
# ---------------------------------------------------------------------------

# The fully populated action, built once for both the field-by-field decode
# subtest and the byte-identity subtest below.
sub make_full_action {
    my $retry_policy = Temporalio::Common::RetryPolicy->new(
        initial_interval          => 5,
        backoff_coefficient       => 1.5,
        maximum_interval          => 120,
        maximum_attempts          => 7,
        non_retryable_error_types => [ 'BadInput', 'Nope' ],
    );
    my $priority = Temporalio::Common::Priority->new(
        priority_key    => 2,
        fairness_key    => 'tenant-1',
        fairness_weight => 3.5,
    );
    my $search_attributes = Temporalio::Common::TypedSearchAttributes->new([
        [ Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField')
            => 'kw-value' ],
        [ Temporalio::Common::SearchAttributeKey->int('CustomIntField') => 42 ],
    ]);

    return Temporalio::Schedule::Action::StartWorkflow->new(
        workflow          => 'RoundTripWorkflow',
        args              => [ 'arg1' ],
        id                => 'sched-roundtrip-wf',
        task_queue        => 'tq-roundtrip',
        execution_timeout => 3600,
        run_timeout       => 1800,
        task_timeout      => 30,
        retry_policy      => $retry_policy,
        memo              => { note => 'memo-value' },
        search_attributes => $search_attributes,
        headers           => { 'X-Trace' => 'trace-value' },
        priority          => $priority,
        static_summary    => 'round trip summary',
        static_details    => 'round trip details',
    );
}

T2->subtest('every optional field survives _to_proto -> _from_proto' => sub {
    my $client = make_client;
    my $action = make_full_action;

    my $proto = $action->_to_proto($client)->get;
    my $info  = $proto->start_workflow;
    my $rebuilt = Temporalio::Schedule::Action::StartWorkflow->_from_proto($info);

    # Fields _from_proto already decoded before this step (sanity).
    T2->is($rebuilt->workflow, 'RoundTripWorkflow', 'workflow');
    T2->is($rebuilt->id, 'sched-roundtrip-wf', 'id');
    T2->is($rebuilt->task_queue, 'tq-roundtrip', 'task_queue');

    # Timeouts (seconds).
    T2->is($rebuilt->execution_timeout, 3600, 'execution_timeout survives');
    T2->is($rebuilt->run_timeout, 1800, 'run_timeout survives');
    T2->is($rebuilt->task_timeout, 30, 'task_timeout survives');

    # retry_policy.
    my $rp = $rebuilt->retry_policy;
    T2->ok(defined $rp, 'retry_policy present');
    T2->isa_ok($rp, 'Temporalio::Common::RetryPolicy');
    T2->is($rp->initial_interval, 5, 'retry_policy initial_interval');
    T2->is($rp->backoff_coefficient, 1.5, 'retry_policy backoff_coefficient');
    T2->is($rp->maximum_interval, 120, 'retry_policy maximum_interval');
    T2->is($rp->maximum_attempts, 7, 'retry_policy maximum_attempts');
    T2->is($rp->non_retryable_error_types, [ 'BadInput', 'Nope' ],
        'retry_policy non_retryable_error_types');

    # priority.
    my $pri = $rebuilt->priority;
    T2->ok(defined $pri, 'priority present');
    T2->isa_ok($pri, 'Temporalio::Common::Priority');
    T2->is($pri->priority_key, 2, 'priority_key');
    T2->is($pri->fairness_key, 'tenant-1', 'fairness_key');
    T2->is($pri->fairness_weight, 3.5, 'fairness_weight');

    # memo: raw pass-through Payload map (no data-converter decode).
    my $memo = $rebuilt->memo;
    T2->ok(defined $memo, 'memo present');
    T2->is($memo->{note}->metadata->{encoding}, 'json/plain',
        'memo value payload encoding');
    T2->is($memo->{note}->data, '"memo-value"', 'memo value payload data');

    # headers: raw pass-through Payload map.
    my $headers = $rebuilt->headers;
    T2->ok(defined $headers, 'headers present');
    T2->is($headers->{'X-Trace'}->metadata->{encoding}, 'json/plain',
        'header value payload encoding');
    T2->is($headers->{'X-Trace'}->data, '"trace-value"', 'header value payload data');

    # search_attributes: decoded typed collection.
    my $sa = $rebuilt->search_attributes;
    T2->ok(defined $sa, 'search_attributes present');
    T2->isa_ok($sa, 'Temporalio::Common::TypedSearchAttributes');
    my %by_name = map { $_->[0]->name => $_->[1] } @{ $sa->pairs };
    T2->is($by_name{CustomKeywordField}, 'kw-value', 'keyword SA value');
    T2->is($by_name{CustomIntField}, 42, 'int SA value');

    # static_summary/static_details: raw pass-through Payloads.
    my $summary = $rebuilt->static_summary;
    T2->ok(defined $summary, 'static_summary present');
    T2->is($summary->metadata->{encoding}, 'json/plain',
        'static_summary payload encoding');
    T2->is($summary->data, '"round trip summary"', 'static_summary payload data');

    my $details = $rebuilt->static_details;
    T2->ok(defined $details, 'static_details present');
    T2->is($details->data, '"round trip details"', 'static_details payload data');
});

# ---------------------------------------------------------------------------
# An action with none of the optional fields decodes them all as undef.
# ---------------------------------------------------------------------------
T2->subtest('an action without optional fields decodes them all undef' => sub {
    my $client = make_client;
    my $action = Temporalio::Schedule::Action::StartWorkflow->new(
        workflow   => 'PlainWorkflow',
        id         => 'sched-plain-wf',
        task_queue => 'tq-plain',
    );

    my $proto   = $action->_to_proto($client)->get;
    my $rebuilt =
        Temporalio::Schedule::Action::StartWorkflow->_from_proto($proto->start_workflow);

    T2->ok(!defined $rebuilt->execution_timeout, 'execution_timeout undef');
    T2->ok(!defined $rebuilt->run_timeout, 'run_timeout undef');
    T2->ok(!defined $rebuilt->task_timeout, 'task_timeout undef');
    T2->ok(!defined $rebuilt->retry_policy, 'retry_policy undef');
    T2->ok(!defined $rebuilt->memo, 'memo undef');
    T2->ok(!defined $rebuilt->headers, 'headers undef');
    T2->ok(!defined $rebuilt->search_attributes, 'search_attributes undef');
    T2->ok(!defined $rebuilt->untyped_search_attributes,
        'untyped_search_attributes undef');
    T2->ok(!defined $rebuilt->priority, 'priority undef');
    T2->ok(!defined $rebuilt->static_summary, 'static_summary undef');
    T2->ok(!defined $rebuilt->static_details, 'static_details undef');
});

# ---------------------------------------------------------------------------
# A describe -> modify -> update cycle must re-emit the exact bytes the server
# sent, not just an equivalent field set: anything _from_proto quietly widens
# or drops shows up here as a byte diff.
# ---------------------------------------------------------------------------
T2->subtest('_to_proto(_from_proto(x)) is byte-identical' => sub {
    my $client  = make_client;
    my $first   = make_full_action->_to_proto($client)->get;
    my $rebuilt = Temporalio::Schedule::Action::StartWorkflow->_from_proto(
        $first->start_workflow);
    my $second  = $rebuilt->_to_proto($client)->get;

    T2->is($second->encode, $first->encode,
        'a describe-modify-update cycle re-emits identical bytes');
});

# ---------------------------------------------------------------------------
# Search-attribute decode. A field the SDK cannot type (no "type" metadata, an
# unknown type, or an undecodable value) is kept verbatim as an untyped
# residual and re-sent on update instead of being dropped. Python contract
# (record file:line): ../sdk-python temporalio/client/_schedule.py
# ScheduleActionStartWorkflow.__init__ (~:719-729) sets
# untyped_search_attributes to decode_search_attributes(...) with every typed
# name removed, and _to_proto (~:838-852) re-encodes "untyped_not_in_typed"
# before the typed set, so a name in both keeps its typed value.
# temporalio/converter/_search_attributes.py decode_typed_search_attributes
# (~:183-202) skips a field with no or unknown type metadata, unwraps a
# single-element list for a non-KeywordList key, and discards a value whose
# type does not match the key. Confirmed live in the checked-out ../sdk-python
# tree.
# ---------------------------------------------------------------------------

# A ScheduleAction carrying exactly the given name -> Payload indexed fields,
# crossed over the wire (encode then decode) so the decode path sees the
# fully blessed sub-messages a server response materializes, per the
# nested-sub-message rule in .ai-sessions/lessons.md.
sub wire_action_with_sas ($indexed_fields) {
    my $WorkflowType = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.WorkflowType');
    my $TaskQueue = Temporalio::Core::Proto::resolve(
        'temporal.api.taskqueue.v1.TaskQueue');
    my $SearchAttributes = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.SearchAttributes');
    my $NewInfo = Temporalio::Core::Proto::resolve(
        'temporal.api.workflow.v1.NewWorkflowExecutionInfo');
    my $Action = Temporalio::Core::Proto::resolve(
        'temporal.api.schedule.v1.ScheduleAction');

    my $action = $Action->new({
        start_workflow => $NewInfo->new({
            workflow_id       => 'sched-untyped-wf',
            workflow_type     => $WorkflowType->new({ name => 'UntypedWorkflow' }),
            task_queue        => $TaskQueue->new({ name => 'tq-untyped' }),
            search_attributes => $SearchAttributes->new(
                { indexed_fields => $indexed_fields }),
        }),
    });
    return $Action->decode($action->encode);
}

T2->subtest('an untyped search attribute survives describe -> update' => sub {
    my $client = make_client;
    my $typed  = Temporalio::Common::SearchAttributeKey
        ->keyword('CustomKeywordField')->encode_value('kw-value');
    # No "type" metadata: the shape a server that indexed the attribute before
    # typed search attributes existed still sends back.
    my $untyped = Temporalio::Payload->new({
        metadata => { encoding => 'json/plain' },
        data     => '["legacy-value"]',
    });

    my $wire = wire_action_with_sas({
        CustomKeywordField => $typed,
        LegacyField        => $untyped,
    });
    my $sent_sas = $wire->start_workflow->search_attributes;

    my $action = Temporalio::Schedule::Action::StartWorkflow->_from_proto(
        $wire->start_workflow);

    my $residual = $action->untyped_search_attributes;
    T2->ok(defined $residual, 'untyped residual present');
    T2->is([ sort keys %$residual ], [ 'LegacyField' ],
        'only the field that could not be typed is held as a residual');
    T2->is([ map { $_->[0]->name } @{ $action->search_attributes->pairs } ],
        [ 'CustomKeywordField' ], 'the typed field decoded normally');

    my $updated = $action->_to_proto($client)->get;
    my $fields  = $updated->start_workflow->search_attributes->indexed_fields;
    T2->is([ sort keys %$fields ], [ 'CustomKeywordField', 'LegacyField' ],
        'both fields are re-emitted on update');
    T2->is($fields->{LegacyField}->encode, $untyped->encode,
        'the untyped field is re-emitted byte-for-byte');
    T2->is($updated->start_workflow->search_attributes->encode,
        $sent_sas->encode, 'the whole SearchAttributes message round-trips');
});

T2->subtest('an SA payload that cannot be decoded is kept, not fatal' => sub {
    my $client = make_client;
    # A null-encoded payload claiming a Keyword type: the data is not JSON, so
    # the typed decode has nothing to produce.
    my $null = Temporalio::Payload->new({
        metadata => { encoding => 'binary/null', type => 'Keyword' },
        data     => '',
    });
    # An unknown type this SDK version has no key factory for.
    my $unknown = Temporalio::Payload->new({
        metadata => { encoding => 'json/plain', type => 'SomeFutureType' },
        data     => '"future"',
    });

    my $wire = wire_action_with_sas({ NullField => $null, FutureField => $unknown });
    my $action;
    T2->ok(
        T2->lives(sub {
            $action = Temporalio::Schedule::Action::StartWorkflow->_from_proto(
                $wire->start_workflow);
        }),
        'an undecodable search attribute does not die');
    T2->ok(!defined $action->search_attributes, 'nothing decoded as typed');
    T2->is([ sort keys %{ $action->untyped_search_attributes } ],
        [ 'FutureField', 'NullField' ], 'both are held as untyped residuals');

    my $updated = $action->_to_proto($client)->get;
    T2->is($updated->start_workflow->search_attributes->encode,
        $wire->start_workflow->search_attributes->encode,
        'both are re-emitted byte-for-byte on update');
});

T2->subtest('a KeywordList the SDK could not re-encode stays untyped' => sub {
    my $client = make_client;
    # A KeywordList-typed payload holding numbers rather than strings. The
    # typed decode has to refuse it for the same reason encode_value would:
    # a decode looser than the re-encode admits the field into the typed
    # collection and then kills the very next update, which is the
    # describe-modify-update failure F9 exists to remove.
    my $numeric_list = Temporalio::Payload->new({
        metadata => { encoding => 'json/plain', type => 'KeywordList' },
        data     => '[1,2]',
    });

    my $wire     = wire_action_with_sas({ NumericTags => $numeric_list });
    my $sent_sas = $wire->start_workflow->search_attributes;
    my $action   = Temporalio::Schedule::Action::StartWorkflow->_from_proto(
        $wire->start_workflow);

    T2->ok(!defined $action->search_attributes,
        'a numeric KeywordList does not decode as typed');
    T2->is([ sort keys %{ $action->untyped_search_attributes // {} } ],
        [ 'NumericTags' ], 'it is held as an untyped residual instead');

    my $updated = $action->_to_proto($client)->get;
    T2->is($updated->start_workflow->search_attributes->encode,
        $sent_sas->encode,
        'the SearchAttributes message re-emits byte-for-byte');
});

T2->subtest('the untyped residual takes wire Payloads only' => sub {
    my %required = (
        workflow   => 'UntypedWorkflow',
        id         => 'sched-untyped-wf',
        task_queue => 'tq-untyped',
    );

    my $bare = T2->dies(sub {
        Temporalio::Schedule::Action::StartWorkflow->new(
            %required,
            _untyped_search_attributes => { Legacy => { bare => 'hash' } },
        );
    });
    T2->ok($bare && $bare->isa('Temporalio::Exception::Argument'),
        'a bare hashref value on the private key is rejected');

    my $scalar = T2->dies(sub {
        Temporalio::Schedule::Action::StartWorkflow->new(
            %required,
            _untyped_search_attributes => { Legacy => 'plain-string' },
        );
    });
    T2->ok($scalar && $scalar->isa('Temporalio::Exception::Argument'),
        'a plain scalar value on the private key is rejected');

    # The decode path, which passes real Payloads, still builds.
    my $untyped = Temporalio::Payload->new({
        metadata => { encoding => 'json/plain' },
        data     => '["legacy-value"]',
    });
    my $wire = wire_action_with_sas({ LegacyField => $untyped });
    my $action;
    T2->ok(
        T2->lives(sub {
            $action = Temporalio::Schedule::Action::StartWorkflow->_from_proto(
                $wire->start_workflow);
        }),
        '_from_proto still constructs with the Payloads it decoded');
    T2->is([ sort keys %{ $action->untyped_search_attributes // {} } ],
        [ 'LegacyField' ], 'the decoded residual is kept');
});

# A payload-shaped object whose metadata accessor returns undef. The generated
# proto class auto-vivifies its map fields, so only a hand-built payload can
# present this shape; the decode loop must still not dereference undef.
package MetadatalessPayload {
    sub new      { return bless {}, shift }
    sub metadata { return undef }
    sub data     { return '"x"' }
}

T2->subtest('a payload with no metadata is skipped, not fatal' => sub {
    my $SearchAttributes = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.SearchAttributes');
    my $sa = $SearchAttributes->new(
        { indexed_fields => { Bare => MetadatalessPayload->new } });

    my $decoded;
    T2->ok(
        T2->lives(sub {
            $decoded = Temporalio::Common::TypedSearchAttributes->_from_proto($sa);
        }),
        'undef metadata does not die');
    T2->is($decoded->pairs, [], 'the field is skipped');
});

# ---------------------------------------------------------------------------
# Every indexed value type, decoded from real wire bytes rather than from the
# in-process message the encoder just built.
# ---------------------------------------------------------------------------
T2->subtest('every indexed value type survives a wire-crossing round trip' => sub {
    my $client = make_client;
    my $key    = 'Temporalio::Common::SearchAttributeKey';

    my $action = Temporalio::Schedule::Action::StartWorkflow->new(
        workflow          => 'SAWorkflow',
        id                => 'sched-sa-wf',
        task_queue        => 'tq-sa',
        search_attributes => Temporalio::Common::TypedSearchAttributes->new([
            [ $key->bool('BoolTrue')         => 1 ],
            [ $key->bool('BoolFalse')        => 0 ],
            [ $key->datetime('When')         => '2026-07-10T12:34:56Z' ],
            [ $key->double('Ratio')          => 1.5 ],
            [ $key->int('Count')             => 42 ],
            [ $key->keyword('Kw')            => 'kw-value' ],
            [ $key->keyword_list('Tags')     => [ 'a', 'b' ] ],
            [ $key->text('Note')             => 'some text' ],
        ]),
    );

    my $Action = Temporalio::Core::Proto::resolve(
        'temporal.api.schedule.v1.ScheduleAction');
    my $wire = $Action->decode($action->_to_proto($client)->get->encode);
    my $rebuilt = Temporalio::Schedule::Action::StartWorkflow->_from_proto(
        $wire->start_workflow);

    my $pairs = $rebuilt->search_attributes->pairs;
    my %by_name = map { $_->[0]->name => $_->[1] } @$pairs;
    T2->is([ sort keys %by_name ],
        [ qw(BoolFalse BoolTrue Count Kw Note Ratio Tags When) ],
        'every value type decoded');
    T2->is($by_name{BoolTrue}, 1, 'Bool true normalizes to 1');
    T2->is($by_name{BoolFalse}, 0, 'Bool false normalizes to 0');
    T2->is($by_name{When}, '2026-07-10T12:34:56Z', 'Datetime stays the ISO string');
    T2->is($by_name{Ratio}, 1.5, 'Double value');
    T2->is($by_name{Count}, 42, 'Int value');
    T2->is($by_name{Kw}, 'kw-value', 'Keyword value');
    T2->is($by_name{Tags}, [ 'a', 'b' ], 'KeywordList value');
    T2->is($by_name{Note}, 'some text', 'Text value');
    T2->ok(!defined $rebuilt->untyped_search_attributes,
        'a fully typed set leaves no residual');

    my %type_of = map { $_->[0]->name => $_->[0]->metadata_type } @$pairs;
    T2->is($type_of{BoolTrue}, 'Bool', 'Bool key type recovered');
    T2->is($type_of{Tags}, 'KeywordList', 'KeywordList key type recovered');
});

# ---------------------------------------------------------------------------
# RetryPolicy decode. A field left unset on a hand-built proto reads undef in
# this proto runtime (a wire-decoded proto fills the proto3 default instead),
# and undef must not override the SDK defaults. Python contract (record
# file:line): ../sdk-python temporalio/common.py RetryPolicy.from_proto
# (~:62-74) reads proto scalars that always carry a value, so the decoded
# policy never holds None for backoff_coefficient or maximum_attempts.
# ---------------------------------------------------------------------------
T2->subtest('RetryPolicy _from_proto keeps the defaults on unset fields' => sub {
    my $RetryPolicy = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.RetryPolicy');

    my $decoded =
        Temporalio::Common::RetryPolicy->_from_proto($RetryPolicy->new({}));
    T2->is($decoded->backoff_coefficient, 2.0, 'backoff_coefficient defaults to 2.0');
    T2->is($decoded->maximum_attempts, 0, 'maximum_attempts defaults to 0 (unlimited)');
    T2->is($decoded->initial_interval, 1, 'initial_interval defaults to 1 second');
    T2->ok(!defined $decoded->maximum_interval, 'maximum_interval stays undef');
    T2->ok(!defined $decoded->non_retryable_error_types,
        'non_retryable_error_types stays undef');

    # An explicitly set field still wins over the default.
    my $explicit = Temporalio::Common::RetryPolicy->_from_proto(
        $RetryPolicy->new({ backoff_coefficient => 1.5, maximum_attempts => 7 }));
    T2->is($explicit->backoff_coefficient, 1.5, 'an explicit backoff_coefficient wins');
    T2->is($explicit->maximum_attempts, 7, 'an explicit maximum_attempts wins');
});

T2->done_testing;
