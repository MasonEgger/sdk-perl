# ABOUTME: I12/F5 pins: the cloud/test/health raw service handles are generated
# ABOUTME: from proto descriptors vendored byte-for-byte from the pinned v0.4.0
# ABOUTME: tag, which holds all four trees under crates/common/protos
# ABOUTME: (api_cloud_upstream, testsrv_upstream, grpc, protoc-gen-openapiv2).
# ABOUTME: Client's three accessors delegate to Connection, each handle stamps
# ABOUTME: its own bridge service => cloud|test|health key (discriminators
# ABOUTME: 3/4/5, header lines 8-14) and its descriptor's response class, and
# ABOUTME: HealthService's server-streaming Watch rpc is skipped.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Temporalio::Client ();
use Temporalio::Client::CloudService ();
use Temporalio::Client::Connection ();
use Temporalio::Client::HealthService ();
use Temporalio::Client::RawService ();
use Temporalio::Client::TestService ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();

# A classic blessed-hash connection double (the raw_service.t precedent: no
# feature-class fixture, so the Test2 bareword exports survive). Captures
# every rpc_call and resolves with a canned marker; the three new accessors
# mirror Connection's own cloud_service/test_service/health_service (a fresh
# handle per call, connection => $self).
package FakeConnection {
    sub new { return bless { calls => [] }, shift }

    sub rpc_call {
        my ($self, $rpc, $request, %opts) = @_;
        push @{ $self->{calls} },
            { rpc => $rpc, request => $request, opts => {%opts} };
        return Future->done('FAKE-RESPONSE');
    }

    sub cloud_service {
        my $self = shift;
        return Temporalio::Client::CloudService->new(connection => $self);
    }

    sub test_service {
        my $self = shift;
        return Temporalio::Client::TestService->new(connection => $self);
    }

    sub health_service {
        my $self = shift;
        return Temporalio::Client::HealthService->new(connection => $self);
    }

    sub calls { $_[0]{calls} }
    sub last_call { $_[0]{calls}[-1] }
}

sub make_client ($connection) {
    return Temporalio::Client->new(
        connection     => $connection,
        namespace      => 'ns-raw-extra',
        identity       => 'id-raw-extra@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

T2->subtest('Client exposes cloud_service/test_service/health_service accessors' => sub {
    my $connection = FakeConnection->new;
    my $client      = make_client($connection);

    my $cloud  = $client->cloud_service;
    my $test   = $client->test_service;
    my $health = $client->health_service;

    T2->isa_ok($cloud,  ['Temporalio::Client::CloudService'],  'cloud_service');
    T2->isa_ok($test,   ['Temporalio::Client::TestService'],   'test_service');
    T2->isa_ok($health, ['Temporalio::Client::HealthService'], 'health_service');

    # Known snake_case rpcs (Python bridge/services_generated.py parity: the
    # CloudService get_users/get_namespaces group, the TestService
    # lock_time_skipping/get_current_time group, HealthService's check).
    T2->ok($cloud->can('get_users'),      'cloud handle: GetUsers -> get_users');
    T2->ok($cloud->can('get_namespaces'), 'cloud handle: GetNamespaces -> get_namespaces');
    T2->ok($test->can('lock_time_skipping'),
        'test handle: LockTimeSkipping -> lock_time_skipping');
    T2->ok($test->can('get_current_time'),
        'test handle: GetCurrentTime -> get_current_time');
    T2->ok($health->can('check'), 'health handle: Check -> check');
});

T2->subtest('generated method maps are non-empty and every method is snake_case' => sub {
    my $schema = Temporalio::Core::Proto::schema();

    for my $case (
        [Temporalio::Client::CloudService->new(connection => FakeConnection->new),
            'temporal.api.cloud.cloudservice.v1.CloudService'],
        [Temporalio::Client::TestService->new(connection => FakeConnection->new),
            'temporal.api.testservice.v1.TestService'],
        [Temporalio::Client::HealthService->new(connection => FakeConnection->new),
            'grpc.health.v1.Health'],
    ) {
        my ($handle, $full_name) = @$case;
        my $descriptor = $schema->service($full_name);
        T2->ok($descriptor, "schema has the $full_name descriptor");
        my @unary = grep {
            !$_->{client_streaming} && !$_->{server_streaming}
        } @{ $descriptor->methods };
        T2->ok(scalar(@unary) > 0, "$full_name has at least one unary rpc");

        my @missing = grep {
            !$handle->can(
                Temporalio::Client::RawService::_snake_case($_->{name}))
        } @unary;
        T2->is(\@missing, [],
            "every $full_name unary rpc has a generated snake_case method");

        for my $rpc (@unary) {
            my $method = Temporalio::Client::RawService::_snake_case($rpc->{name});
            T2->like($method, qr/\A[a-z][a-z0-9_]*\z/,
                "$full_name method '$method' is snake_case");
        }
    }
});

T2->subtest('HealthService skips the server-streaming Watch rpc' => sub {
    my $health = Temporalio::Client::HealthService->new(
        connection => FakeConnection->new);
    T2->ok($health->can('check'), 'check is generated (unary)');
    T2->ok(!$health->can('watch'), 'watch is NOT generated (server-streaming)');

    my $schema     = Temporalio::Core::Proto::schema();
    my $descriptor = $schema->service('grpc.health.v1.Health');
    my ($watch) = grep { $_->{name} eq 'Watch' } @{ $descriptor->methods };
    T2->ok($watch, 'the descriptor does list Watch');
    T2->ok($watch->{server_streaming}, 'and it is server-streaming');
});

T2->subtest('the bridge service discriminators are pinned to the C header' => sub {
    # TemporalCoreRpcService, lines 8-14 of
    # ../sdk-rust/crates/sdk-core-c-bridge/include/temporal-sdk-core-c-bridge.h
    # at the pinned v0.4.0 tag:
    #
    #     typedef enum TemporalCoreRpcService {
    #       Workflow = 1,
    #       Operator,
    #       Cloud,
    #       Test,
    #       Health,
    #     } TemporalCoreRpcService;
    #
    # Only the first arm carries a literal, so the other four are positional:
    # inserting a service ahead of Cloud renumbers everything after it. These
    # are the integers Connection::rpc_call hands the c-bridge, so a wrong one
    # dispatches a cloud call at the test service. Before F5 the values lived
    # in a file lexical no test read, and the "discriminator 3/4/5" phrases in
    # the subtest below were decoration.
    my %expected = (
        workflow => 1,
        operator => 2,
        cloud    => 3,
        test     => 4,
        health   => 5,
    );

    T2->is(Temporalio::Client::Connection->_service_code($_), $expected{$_},
        "service '$_' is discriminator $expected{$_}")
        for sort keys %expected;

    T2->is([Temporalio::Client::Connection->_service_names],
        [sort keys %expected],
        'those five are the only service keys rpc_call accepts');
    T2->is(Temporalio::Client::Connection->_service_code('nope'), undef,
        'an unknown service key reads back undef (rpc_call throws on it)');
    T2->is(Temporalio::Client::Connection->_service_code(undef), undef,
        'and so does an undefined key, without an uninitialized warning');
});

T2->subtest('rpc_call rejects a service key outside that table' => sub {
    # The lookup and the error text moved behind _service_code/_service_names
    # in F5, so the dispatch path gets its own assertion: a typo'd service key
    # has to surface as an Argument throw naming the five accepted keys, not
    # as a bare undef discriminator handed to the c-bridge.
    #
    # A deferred connect rather than a synthetic pointer, for two reasons:
    # rpc_call runs the service lookup before it awaits connected_ptr, so the
    # coderef below standing in for a live connect is itself the assertion
    # that the guard fires first; and a connection holding no pointer is
    # reclaimed without DESTROY's free-without-close warning.
    my $connection = Temporalio::Client::Connection->new(
        runtime => undef,
        connect => sub { die "rpc_call reached the deferred connect\n" },
    );
    my $request = Temporalio::Core::Proto::resolve(
        'temporal.api.cloud.cloudservice.v1.GetUsersRequest')->new({});

    my $error = T2->dies(sub {
        $connection->rpc_call('GetUsers', $request, service => 'nope')->get;
    });
    T2->ok($error, 'an unknown service key dies');
    T2->isa_ok($error, ['Temporalio::Exception::Argument'],
        'as an Argument exception');
    T2->like($error->message,
        qr/\Aunknown RPC service 'nope' \(expected one of cloud, health, operator, test, workflow\)\z/,
        'naming the bad key and listing the five rpc_call accepts');
});

T2->subtest('the cloud protos carry the pinned tag vintage, not a later one'
    => sub {
        # F5: every vendored cloud/testservice/health/openapiv2 file is
        # byte-identical to v0.4.0:crates/common/protos/<tree>/<path>. The one
        # file that had drifted was connectivityrule/v1/message.proto, where a
        # post-tag upstream added `bool enable_stable_ips = 1` to
        # PublicConnectivityRule. The installed 0.4.0 c-bridge decodes cloud
        # responses with its own prost types, so a field the tag does not know
        # is dropped on the way through and a Perl caller would read a value
        # that never survives the round trip. An empty PublicConnectivityRule
        # is the tag's shape; this fails the moment someone re-vendors from a
        # sdk-rust checkout HEAD instead of from the pin.
        my $schema  = Temporalio::Core::Proto::schema();
        my $public  = $schema->message(
            'temporal.api.cloud.connectivityrule.v1.PublicConnectivityRule');
        T2->ok($public, 'the cloud connectivityrule tree is in the schema');
        T2->is([map { $_->name } @{ $public->fields }], [],
            'PublicConnectivityRule has no fields at the pinned tag');

        # Control: a sibling in the same file that does carry fields, so the
        # assertion above cannot pass by resolving an empty stub.
        my $private = $schema->message(
            'temporal.api.cloud.connectivityrule.v1.PrivateConnectivityRule');
        T2->is([map { $_->name } @{ $private->fields }],
            [qw(connection_id gcp_project_id region)],
            'PrivateConnectivityRule still carries its three fields');
    });

T2->subtest('each handle stamps its own bridge service key' => sub {
    my $connection = FakeConnection->new;
    my $cloud      = $connection->cloud_service;
    my $test       = $connection->test_service;
    my $health     = $connection->health_service;

    my $req = Temporalio::Core::Proto::resolve(
        'temporal.api.cloud.cloudservice.v1.GetUsersRequest')->new({});
    my $future = $cloud->get_users($req);
    T2->ok($future->is_ready, 'the wrapper returns the rpc_call future');
    T2->is($future->get, 'FAKE-RESPONSE', 'resolving with the rpc_call result');
    T2->is($connection->last_call->{rpc}, 'GetUsers',
        'the CamelCase rpc name the c-bridge dispatches on rides through');
    T2->ref_is($connection->last_call->{request}, $req,
        'the request message rides through');
    T2->is($connection->last_call->{opts}{service}, 'cloud',
        'the cloud handle stamps service => cloud (discriminator 3)');

    # The response class comes from the rpc's descriptor output type, not from
    # rpc_call's s/Request$/Response/ fallback (raw_service.t pins the same
    # thing for the operator service). Both spellings are asserted: the
    # resolved class, and the literal package the proto-to-Perl mapping
    # produces for the cloud package, which nothing else in the suite pins.
    T2->is($connection->last_call->{opts}{response_class},
        Temporalio::Core::Proto::resolve(
            'temporal.api.cloud.cloudservice.v1.GetUsersResponse'),
        'the response class comes from the descriptor output type');
    T2->is($connection->last_call->{opts}{response_class},
        'Temporalio::Proto::Api::Cloud::Cloudservice::V1::GetUsersResponse',
        'and it is the generated class for the cloud proto package');

    $test->get_current_time(
        Temporalio::Core::Proto::resolve('google.protobuf.Empty')->new({}));
    T2->is($connection->last_call->{rpc}, 'GetCurrentTime',
        'the test handle forwards its rpc name verbatim');
    T2->is($connection->last_call->{opts}{service}, 'test',
        'the test handle stamps service => test (discriminator 4)');

    $health->check(
        Temporalio::Core::Proto::resolve('grpc.health.v1.HealthCheckRequest')
            ->new({}));
    T2->is($connection->last_call->{rpc}, 'Check',
        'the health handle forwards its rpc name verbatim');
    T2->is($connection->last_call->{opts}{service}, 'health',
        'the health handle stamps service => health (discriminator 5)');
});

T2->done_testing;
