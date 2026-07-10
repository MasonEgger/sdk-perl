# ABOUTME: Deterministic pins for the R91 raw service handles: the per-rpc
# ABOUTME: methods are GENERATED from the proto service descriptors (not
# ABOUTME: hand-listed), each wrapper passes the CamelCase rpc name plus the
# ABOUTME: descriptor-resolved response class to Connection::rpc_call, and
# ABOUTME: the two service surfaces stay distinct. Live path is
# ABOUTME: t/integration/raw_service_client.t.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use lib 'lib';

use Future ();
use Temporalio::Client::OperatorService ();
use Temporalio::Client::RawService ();
use Temporalio::Client::WorkflowService ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Runtime ();

# A classic blessed-hash connection double (the Interceptor-Input precedent:
# no feature-class fixture, so the Test2 bareword exports survive). Captures
# every rpc_call and resolves with a canned marker.
package FakeConnection {
    sub new { return bless { calls => [] }, shift }

    sub rpc_call {
        my ($self, $rpc, $request, %opts) = @_;
        push @{ $self->{calls} },
            { rpc => $rpc, request => $request, opts => {%opts} };
        return Future->done('FAKE-RESPONSE');
    }

    sub calls { $_[0]{calls} }
    sub last_call { $_[0]{calls}[-1] }
}

T2->subtest('methods are generated from the proto service descriptors' => sub {
    my $wf = Temporalio::Client::WorkflowService->new(
        connection => FakeConnection->new);
    my $op = Temporalio::Client::OperatorService->new(
        connection => FakeConnection->new);

    # One method per descriptor rpc, snake_cased.
    my $schema = Temporalio::Core::Proto::schema();
    for my $case (
        [$wf, 'temporal.api.workflowservice.v1.WorkflowService'],
        [$op, 'temporal.api.operatorservice.v1.OperatorService'],
    ) {
        my ($handle, $full_name) = @$case;
        my $descriptor = $schema->service($full_name);
        T2->ok($descriptor, "schema has the $full_name descriptor");
        my @missing = grep {
            !$handle->can(
                Temporalio::Client::RawService::_snake_case($_->{name}))
        } @{ $descriptor->methods };
        T2->is(\@missing, [],
            "every $full_name descriptor rpc has a generated method");
    }

    # Spot-check the names Python's generated services use.
    T2->ok($wf->can('get_system_info'),
        'workflow handle: GetSystemInfo -> get_system_info');
    T2->ok($wf->can('count_workflow_executions'),
        'workflow handle: CountWorkflowExecutions -> count_workflow_executions');
    T2->ok($op->can('add_search_attributes'),
        'operator handle: AddSearchAttributes -> add_search_attributes');
    T2->ok($op->can('add_or_update_remote_cluster'),
        'operator handle: AddOrUpdateRemoteCluster -> add_or_update_remote_cluster');

    # Distinct per-service surfaces (Python has one generated class per
    # service): no operator rpc on the workflow handle and vice versa.
    T2->ok(!$wf->can('add_search_attributes'),
        'workflow handle does not expose operator rpcs');
    T2->ok(!$op->can('get_system_info'),
        'operator handle does not expose workflow rpcs');
});

T2->subtest('generated wrappers drive Connection::rpc_call with descriptor data' => sub {
    my $connection = FakeConnection->new;
    my $op         = Temporalio::Client::OperatorService->new(
        connection => $connection);

    my $request = Temporalio::Core::Proto::resolve(
        'temporal.api.operatorservice.v1.AddSearchAttributesRequest')
        ->new({ namespace => 'default' });
    my $future = $op->add_search_attributes($request);

    T2->ok($future->is_ready, 'the wrapper returns the rpc_call future');
    T2->is($future->get, 'FAKE-RESPONSE', 'resolving with the rpc_call result');

    my $call = $connection->last_call;
    T2->is($call->{rpc}, 'AddSearchAttributes',
        'the CamelCase rpc name the c-bridge dispatches on rides through');
    T2->ref_is($call->{request}, $request, 'the request message rides through');
    T2->is($call->{opts}{service}, 'operator',
        'the handle stamps its own bridge service key');
    T2->is($call->{opts}{response_class},
        Temporalio::Core::Proto::resolve(
            'temporal.api.operatorservice.v1.AddSearchAttributesResponse'),
        'the response class comes from the descriptor output type');
    T2->ok(!exists $call->{opts}{retry},
        'no retry opt is injected; Connection::rpc_call owns the raw'
      . ' single-shot default');

    # Caller options ride through (and may override the descriptor default).
    $op->add_search_attributes($request, retry => 1, timeout => 5);
    T2->is($connection->last_call->{opts}{retry}, 1, 'caller retry rides through');
    T2->is($connection->last_call->{opts}{timeout}, 5,
        'caller timeout rides through');
});

T2->subtest('generic call() passes an arbitrary CamelCase rpc through' => sub {
    my $connection = FakeConnection->new;
    my $wf         = Temporalio::Client::WorkflowService->new(
        connection => $connection);

    my $request = Temporalio::Core::Proto::resolve(
        'temporal.api.workflowservice.v1.GetSystemInfoRequest')->new({});
    $wf->call('GetSystemInfo', $request);
    T2->is($connection->last_call->{rpc}, 'GetSystemInfo',
        'call() forwards the rpc name verbatim');
    T2->is($connection->last_call->{opts}{service}, 'workflow',
        'call() stamps the workflow service key');
});

T2->subtest('snake_case conversion matches the protoc convention' => sub {
    my %cases = (
        GetSystemInfo                     => 'get_system_info',
        AddOrUpdateRemoteCluster          => 'add_or_update_remote_cluster',
        RespondActivityTaskCompletedById  => 'respond_activity_task_completed_by_id',
        ListSchedules                     => 'list_schedules',
        PollWorkflowExecutionUpdate       => 'poll_workflow_execution_update',
    );
    for my $camel (sort keys %cases) {
        T2->is(Temporalio::Client::RawService::_snake_case($camel),
            $cases{$camel}, "$camel -> $cases{$camel}");
    }
});

T2->subtest('install_rpc_methods rejects an unknown service' => sub {
    my $error = T2->dies(sub {
        Temporalio::Client::RawService::install_rpc_methods(
            'My::Bogus::Target', 'temporal.api.nosuch.v1.NoSuchService');
    });
    T2->ok($error, 'unknown service dies');
    T2->isa_ok($error, ['Temporalio::Exception::Runtime'], 'as a Runtime exception');
    T2->like($error->message, qr/no proto service descriptor/,
        'with the no-descriptor message');
});

T2->done_testing;
