# ABOUTME: Unit tests for the spec section 7.4 StartWorkflowExecutionRequest /
# ABOUTME: SignalWithStartWorkflowExecutionRequest builder — kwargs->proto field
# ABOUTME: mapping, the MUST-match id_reuse/id_conflict enums, and pre-RPC guards.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Client ();
use Temporalio::Common::RetryPolicy ();
use Temporalio::Common::Priority ();
use Temporalio::Common::SearchAttributeKey ();
use Temporalio::Common::TypedSearchAttributes ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();

Temporalio::Core::Proto->load;

# A client built without a live connection: the request builder never touches
# the connection pointer, only namespace/identity/data_converter.
sub make_client (%override) {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => $override{namespace} // 'ns-test',
        identity       => $override{identity}  // 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# ---------------------------------------------------------------------------
# Full kwargs -> StartWorkflowExecutionRequest
# ---------------------------------------------------------------------------
T2->subtest('all kwargs land in the right request fields' => sub {
    my $client = make_client;
    my $sa = Temporalio::Common::TypedSearchAttributes->new([
        [ Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField') => 'x' ],
    ]);

    my $req = $client->_build_start_workflow_request(
        'MyWorkflow',
        [ 'Alice', 42 ],
        id                => 'wf-1',
        task_queue        => 'demo',
        execution_timeout => 3600,
        run_timeout       => 600,
        task_timeout      => 10,
        id_reuse_policy   => 'allow_duplicate',
        id_conflict_policy => 'fail',
        retry_policy      => Temporalio::Common::RetryPolicy->new(
            initial_interval => 1, maximum_attempts => 5),
        cron_schedule     => '0 * * * *',
        memo              => { foo => 'bar' },
        search_attributes => $sa,
        headers           => { 'x-trace-id' => 'abc' },
        priority          => Temporalio::Common::Priority->new(priority_key => 1),
        start_delay       => 60,
        request_eager_start => 0,
    )->get;

    T2->isa_ok($req,
        'Temporalio::Proto::Api::Workflowservice::V1::StartWorkflowExecutionRequest');

    T2->is($req->namespace, 'ns-test', 'namespace from client');
    T2->is($req->workflow_id, 'wf-1', 'workflow_id from id');
    T2->is($req->workflow_type->name, 'MyWorkflow', 'workflow_type.name');
    T2->is($req->task_queue->name, 'demo', 'task_queue.name');
    T2->is($req->identity, 'id-test@host', 'identity from client');
    T2->ok(length($req->request_id) > 0, 'request_id populated (uuid)');

    # args -> input.payloads via the data converter. A bare Perl string is
    # treated as text and encodes json/plain (binary/plain is reserved for
    # RawBytes-wrapped values, spec 5.2); the integer 42 also encodes json/plain.
    my @payloads = $req->input->payloads->@*;
    T2->is(scalar(@payloads), 2, 'two args -> two payloads');
    T2->is($payloads[0]->metadata->{encoding}, 'json/plain', 'arg0 json/plain');
    T2->is($payloads[0]->data, '"Alice"', 'arg0 data (JSON string)');
    T2->is($payloads[1]->metadata->{encoding}, 'json/plain', 'arg1 json/plain');
    T2->is($payloads[1]->data, '42', 'arg1 data');

    # timeouts -> Duration
    T2->is($req->workflow_execution_timeout->seconds, 3600, 'execution_timeout');
    T2->is($req->workflow_run_timeout->seconds, 600, 'run_timeout');
    T2->is($req->workflow_task_timeout->seconds, 10, 'task_timeout');
    T2->is($req->workflow_start_delay->seconds, 60, 'start_delay -> Duration');

    # policies (numeric enums)
    T2->is($req->workflow_id_reuse_policy, 1, 'allow_duplicate -> 1');
    T2->is($req->workflow_id_conflict_policy, 1, 'fail -> 1');

    # retry / cron / priority
    T2->is($req->retry_policy->maximum_attempts, 5, 'retry_policy embedded');
    T2->is($req->cron_schedule, '0 * * * *', 'cron_schedule');
    T2->is($req->priority->priority_key, 1, 'priority embedded');

    # memo / headers -> map<string, Payload>; bare string values encode
    # json/plain through the same converter as args.
    T2->is($req->memo->fields->{foo}->data, '"bar"', 'memo value encoded (JSON string)');
    T2->is($req->memo->fields->{foo}->metadata->{encoding}, 'json/plain',
        'memo value json/plain');
    T2->is($req->header->fields->{'x-trace-id'}->data, '"abc"',
        'header value encoded (JSON string)');

    # search attributes
    T2->is($req->search_attributes->indexed_fields->{CustomKeywordField}
            ->metadata->{type}, 'Keyword', 'search_attributes embedded');

    # round-trips on the wire
    my $class = ref $req;
    my $back  = $class->decode($req->encode);
    T2->is($back->workflow_id, 'wf-1', 'survives encode/decode');
});

# ---------------------------------------------------------------------------
# Defaults / omitted fields
# ---------------------------------------------------------------------------
T2->subtest('minimal request omits unset optionals' => sub {
    my $client = make_client;
    my $req = $client->_build_start_workflow_request(
        'W', [],
        id => 'wf-2', task_queue => 'q',
    )->get;

    T2->is($req->workflow_id, 'wf-2', 'workflow_id');
    T2->ok(!defined $req->input, 'no args -> no input payloads');
    T2->ok(!defined $req->workflow_execution_timeout, 'no execution_timeout');
    T2->ok(!defined $req->retry_policy, 'no retry_policy');
    T2->ok(!defined $req->memo, 'no memo');
    T2->ok(!defined $req->priority, 'no priority');
    # unspecified policies default to 0
    T2->is($req->workflow_id_reuse_policy // 0, 0, 'reuse policy default 0');
    T2->is($req->workflow_id_conflict_policy // 0, 0, 'conflict policy default 0');
});

# ---------------------------------------------------------------------------
# Each id_reuse_policy string -> the right enum number (T-cli-start-3)
# ---------------------------------------------------------------------------
T2->subtest('id_reuse_policy strings map to proto enums' => sub {
    my %expect = (
        unspecified                 => 0,
        allow_duplicate             => 1,
        allow_duplicate_failed_only => 2,
        reject_duplicate            => 3,
        terminate_if_running        => 4,
    );
    my $client = make_client;
    for my $name (sort keys %expect) {
        my $req = $client->_build_start_workflow_request(
            'W', [], id => 'wf', task_queue => 'q',
            id_reuse_policy => $name)->get;
        T2->is($req->workflow_id_reuse_policy, $expect{$name},
            "$name -> $expect{$name}");
    }
});

T2->subtest('id_conflict_policy strings map to proto enums' => sub {
    my %expect = (
        unspecified        => 0,
        fail               => 1,
        use_existing       => 2,
        terminate_existing => 3,
    );
    my $client = make_client;
    for my $name (sort keys %expect) {
        my $req = $client->_build_start_workflow_request(
            'W', [], id => 'wf', task_queue => 'q',
            id_conflict_policy => $name)->get;
        T2->is($req->workflow_id_conflict_policy, $expect{$name},
            "$name -> $expect{$name}");
    }
});

# ---------------------------------------------------------------------------
# Invalid policy strings raise Argument before any RPC (T-cli-start-4)
# ---------------------------------------------------------------------------
T2->subtest('invalid id_reuse_policy raises Argument pre-RPC' => sub {
    my $client = make_client;
    my $err = T2->dies(sub {
        $client->_build_start_workflow_request(
            'W', [], id => 'wf', task_queue => 'q',
            id_reuse_policy => 'bogus')->get;
    });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'bad id_reuse_policy -> Argument');
    T2->like("$err", qr/id_reuse_policy/, 'message names the field');
});

T2->subtest('invalid id_conflict_policy raises Argument pre-RPC' => sub {
    my $client = make_client;
    my $err = T2->dies(sub {
        $client->_build_start_workflow_request(
            'W', [], id => 'wf', task_queue => 'q',
            id_conflict_policy => 'nope')->get;
    });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'bad id_conflict_policy -> Argument');
});

# ---------------------------------------------------------------------------
# Required-arg guards
# ---------------------------------------------------------------------------
T2->subtest('id and task_queue are required' => sub {
    my $client = make_client;
    my $no_id = T2->dies(sub {
        $client->_build_start_workflow_request('W', [], task_queue => 'q')->get;
    });
    T2->ok($no_id && $no_id->isa('Temporalio::Exception::Argument'),
        'missing id -> Argument');

    my $no_tq = T2->dies(sub {
        $client->_build_start_workflow_request('W', [], id => 'wf')->get;
    });
    T2->ok($no_tq && $no_tq->isa('Temporalio::Exception::Argument'),
        'missing task_queue -> Argument');
});

# ---------------------------------------------------------------------------
# signal_with_start builds the SignalWithStart variant
# ---------------------------------------------------------------------------
T2->subtest('signal_with_start request carries signal name + args' => sub {
    my $client = make_client;
    my $req = $client->_build_signal_with_start_workflow_request(
        'W', [ 'arg' ],
        id => 'wf-s', task_queue => 'q',
        signal => 'greet', signal_args => [ 'hi' ],
    )->get;

    T2->isa_ok($req,
        'Temporalio::Proto::Api::Workflowservice::V1::SignalWithStartWorkflowExecutionRequest');
    T2->is($req->workflow_id, 'wf-s', 'workflow_id');
    T2->is($req->signal_name, 'greet', 'signal_name');
    T2->is($req->signal_input->payloads->[0]->data, '"hi"', 'signal arg payload (json/plain)');
    T2->is($req->input->payloads->[0]->data, '"arg"', 'workflow arg payload (json/plain)');
});

T2->subtest('signal_with_start requires a signal name' => sub {
    my $client = make_client;
    my $err = T2->dies(sub {
        $client->_build_signal_with_start_workflow_request(
            'W', [], id => 'wf', task_queue => 'q')->get;
    });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'missing signal -> Argument');
});

# ---------------------------------------------------------------------------
# get_workflow_handle / start_workflow return a WorkflowHandle (fields only)
# ---------------------------------------------------------------------------
T2->subtest('get_workflow_handle returns a handle without an RPC' => sub {
    my $client = make_client;
    my $handle = $client->get_workflow_handle('wf-9',
        run_id => 'run-9', first_execution_run_id => 'first-9');
    T2->isa_ok($handle, 'Temporalio::Client::WorkflowHandle');
    T2->is($handle->workflow_id, 'wf-9', 'workflow_id');
    T2->is($handle->run_id, 'run-9', 'run_id');
    T2->is($handle->first_execution_run_id, 'first-9', 'first_execution_run_id');
});

T2->done_testing;
