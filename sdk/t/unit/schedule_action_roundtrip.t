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
T2->subtest('every optional field survives _to_proto -> _from_proto' => sub {
    my $client = make_client;

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

    my $action = Temporalio::Schedule::Action::StartWorkflow->new(
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
    T2->ok(!defined $rebuilt->static_summary, 'static_summary undef');
    T2->ok(!defined $rebuilt->static_details, 'static_details undef');
});

T2->done_testing;
