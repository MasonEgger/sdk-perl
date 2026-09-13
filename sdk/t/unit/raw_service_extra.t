# ABOUTME: I12 pins: the cloud/test/health raw service handles are generated
# ABOUTME: from the newly vendored proto descriptors (../sdk-rust checkout HEAD
# ABOUTME: 3839fa94, api_cloud_upstream/testsrv_upstream/grpc trees; the pinned
# ABOUTME: v0.4.0 tag predates them), Client's three new accessors delegate to
# ABOUTME: Connection, each handle stamps its own bridge service =>
# ABOUTME: cloud|test|health key (discriminator values 3/4/5, header lines
# ABOUTME: 8-14), and HealthService's server-streaming Watch rpc is skipped.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Temporalio::Client ();
use Temporalio::Client::CloudService ();
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
    T2->is($connection->last_call->{opts}{service}, 'cloud',
        'the cloud handle stamps service => cloud (discriminator 3)');

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
