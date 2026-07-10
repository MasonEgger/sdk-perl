# ABOUTME: Unit tests for Nexus handler definitions (spec sections 26.2, 26.4, 10.1).
# ABOUTME: Covers :NexusService/:SyncOperation/:WorkflowRunOperation registration,
# ABOUTME: the four section 10.1 constraints, the gRPC->Nexus MUST-match table, and
# ABOUTME: the operation-token round-trip (T-nexus-11, T-nexus-14 unit portion).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
use Future::AsyncAwait;
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Nexus;
use Temporalio::Nexus::Definition;
use Temporalio::Nexus::WorkflowHandle;
use Temporalio::Worker::NexusRegistry;
use Temporalio::Exception::Argument;

no warnings 'experimental::class';

# ---------------------------------------------------------------------------
# Fixture Nexus service. Declared with feature 'class' and inheriting
# Temporalio::Nexus::Definition so the :NexusService/:SyncOperation/
# :WorkflowRunOperation handlers (which live in the base, per the section 10.1
# constraints) register. Only ONE :isa class parses per file; extra :isa
# fixtures with their own classes live in t/lib/NexusDef/*.pm (required below).
# This default-named service (no :NexusService) verifies the class-basename
# default (spec section 26.2).
# ---------------------------------------------------------------------------
class NexusDef::Defaulted :isa(Temporalio::Nexus::Definition) {
    method say_hello :SyncOperation('say-hello') ($ctx, $name) {
        return "Hello, $name!";
    }

    async method echo :WorkflowRunOperation ($ctx, $input) {
        return $input;
    }
}

# T-nexus-11: a service with no :NexusService defaults the service name to the
# class basename, and its operations register with the right kind.
T2->subtest('T-nexus-11: default service name + operation registration' => sub {
    T2->is(NexusDef::Defaulted->_nexus_service_name, 'Defaulted',
        'service name defaults to the class basename');

    my $ops = NexusDef::Defaulted->_nexus_operations;
    T2->is([sort keys %$ops], ['echo', 'say-hello'],
        'both operations registered (sync name explicit, workflow-run defaults to method)');
    T2->is($ops->{'say-hello'}{kind}, 'sync', ':SyncOperation registers kind=sync');
    T2->is($ops->{'echo'}{kind}, 'workflow_run',
        ':WorkflowRunOperation registers kind=workflow_run');
    T2->is(ref($ops->{'say-hello'}{code}), 'CODE', 'sync op carries a code ref');

    # The captured method ref runs the operation body on an instance.
    my $inst = NexusDef::Defaulted->new;
    my $ref  = $ops->{'say-hello'}{code};
    T2->is($inst->$ref(undef, 'World'), 'Hello, World!',
        'captured method ref runs the operation body');
});

# T-nexus-11: explicit :NexusService and explicit operation names.
require NexusDef::CustomNames;
T2->subtest('T-nexus-11: explicit :NexusService + operation names' => sub {
    T2->is(NexusDef::CustomNames->_nexus_service_name, 'custom-service',
        ':NexusService overrides the service name');
    my $ops = NexusDef::CustomNames->_nexus_operations;
    T2->is([sort keys %$ops], ['echo-op', 'say-hello'],
        'operations registered under their explicit names');
});

# T-nexus-11: the four section 10.1 constraints. The proof that they hold is
# that the BEGIN-phase handlers in the base class fired for the subclasses above
# (constraints 1-3: base declared with `class`, handlers in the chain,
# :ATTR(CODE,BEGIN)). Constraint 4 ($data is arrayref-or-undef): the default
# :WorkflowRunOperation above carried NO argument (undef $data) and still
# registered under its method name, while the explicit forms carried an
# arrayref. A duplicate operation name within a service is rejected at compile
# time.
T2->subtest('T-nexus-11: duplicate operation name raises at compile time' => sub {
    # A BEGIN-phase Attribute::Handlers throw during `require` surfaces as a
    # compile error carrying the message (the blessing does not survive the
    # require boundary — same as WfDef::DupSignal in workflow_definition.t), so
    # assert on the message, not the class.
    my $err = T2->dies(sub { require NexusDef::DupOp });
    T2->ok($err, 'loading a service with a duplicate operation name dies');
    T2->like("$err", qr/Multiple Nexus operations named 'dup'/,
        'the message names the duplicated operation');
});

# ---------------------------------------------------------------------------
# Registry (spec section 26.2). Accepts class names and instances; builds
# service => { operation => callable }; rejects duplicate service names.
# ---------------------------------------------------------------------------
T2->subtest('T-nexus-11: registry resolves classes + instances' => sub {
    my $reg = Temporalio::Worker::NexusRegistry->new(
        nexus_services => ['NexusDef::CustomNames', NexusDef::Defaulted->new],
    );
    T2->is(
        [sort keys %{ $reg->services }],
        ['Defaulted', 'custom-service'],
        'both services registered under their resolved names',
    );

    my $op = $reg->operation('custom-service', 'say-hello');
    T2->ok($op, 'operation lookup by (service, op) succeeds');
    T2->is($op->{kind}, 'sync', 'operation kind preserved through the registry');
    # The registry-bound code binds the shared instance and takes ($ctx, $input).
    T2->is($op->{code}->(undef, 'World'), 'Hello, World!',
        'registry-bound code runs the operation body');

    T2->is($reg->operation('custom-service', 'nope'), undef,
        'unknown operation returns undef');
    T2->is($reg->operation('no-such-service', 'x'), undef,
        'unknown service returns undef');
});

T2->subtest('duplicate service name raises Argument' => sub {
    my $err = T2->dies(sub {
        Temporalio::Worker::NexusRegistry->new(
            nexus_services => ['NexusDef::CustomNames', 'NexusDef::CustomNames'],
        );
    });
    T2->ok(
        Scalar::Util::blessed($err) && $err->isa('Temporalio::Exception::Argument'),
        'a duplicate service name is rejected with Argument',
    );
});

T2->subtest('invalid Nexus service entry raises Argument' => sub {
    my $err = T2->dies(sub {
        Temporalio::Worker::NexusRegistry->new(nexus_services => [ {} ]);
    });
    T2->ok(
        Scalar::Util::blessed($err) && $err->isa('Temporalio::Exception::Argument'),
        'a bare hashref is rejected with Argument',
    );
});

# ---------------------------------------------------------------------------
# T-nexus-14 (unit portion): gRPC status -> Nexus type MUST-match table.
# Spot-checks transcribed from sdk-python worker/_nexus.py:517-573.
# ---------------------------------------------------------------------------
T2->subtest('T-nexus-14: gRPC->Nexus error-type MUST-match table' => sub {
    my @cases = (
        # status               => [type,               retryable_override]
        ['INVALID_ARGUMENT'    => ['BAD_REQUEST',        undef]],
        ['ALREADY_EXISTS'      => ['INTERNAL',           0]],
        ['FAILED_PRECONDITION' => ['INTERNAL',           0]],
        ['OUT_OF_RANGE'        => ['INTERNAL',           0]],
        ['RESOURCE_EXHAUSTED'  => ['RESOURCE_EXHAUSTED', undef]],
        ['UNIMPLEMENTED'       => ['NOT_IMPLEMENTED',    undef]],
        ['DEADLINE_EXCEEDED'   => ['UPSTREAM_TIMEOUT',   undef]],
        ['NOT_FOUND'           => ['NOT_FOUND',          undef]],
        ['CANCELLED'           => ['INTERNAL',           undef]],
        ['DATA_LOSS'           => ['INTERNAL',           undef]],
        ['INTERNAL'            => ['INTERNAL',           undef]],
        ['UNKNOWN'             => ['INTERNAL',           undef]],
        ['UNAUTHENTICATED'     => ['INTERNAL',           undef]],
        ['PERMISSION_DENIED'   => ['INTERNAL',           undef]],
        ['UNAVAILABLE'         => ['UNAVAILABLE',        undef]],
        ['ABORTED'             => ['UNAVAILABLE',        undef]],
        ['SOMETHING_ELSE'      => ['INTERNAL',           undef]],   # else -> INTERNAL
    );
    for my $case (@cases) {
        my ($status, $expect) = @$case;
        my ($type, $override) =
            Temporalio::Nexus::grpc_status_to_nexus_type($status);
        T2->is($type, $expect->[0], "$status -> $expect->[0]");
        T2->is($override, $expect->[1],
            "$status retryable_override matches");
    }
});

# ---------------------------------------------------------------------------
# Operation-token round-trip (spec section 26.2, MUST-match sdk-python
# nexus/_token.py). Encode -> base64url no-padding; decode validates type +
# wid + ns. A malformed token raises Argument.
# ---------------------------------------------------------------------------
T2->subtest('WorkflowHandle operation-token round-trip' => sub {
    my $handle = Temporalio::Nexus::WorkflowHandle->new(
        namespace => 'default', workflow_id => 'op-wf-1');
    my $token = $handle->to_token;
    T2->ok(length $token, 'to_token produces a non-empty token');
    T2->unlike($token, qr/=/, 'token has no base64 padding (sdk-python compat)');

    my $back = Temporalio::Nexus::WorkflowHandle->from_token($token);
    T2->is($back->namespace, 'default', 'namespace round-trips');
    T2->is($back->workflow_id, 'op-wf-1', 'workflow_id round-trips');

    # A python-produced token decodes (compact JSON {"t":1,"ns":...,"wid":...}).
    require MIME::Base64;
    my $py = MIME::Base64::encode_base64url(
        '{"t":1,"ns":"ns2","wid":"wf2"}', '');
    $py =~ s/=+\z//;
    my $h2 = Temporalio::Nexus::WorkflowHandle->from_token($py);
    T2->is($h2->workflow_id, 'wf2', 'a compact python-shaped token decodes');

    my $err = T2->dies(sub {
        Temporalio::Nexus::WorkflowHandle->from_token('') });
    T2->ok($err, 'an empty token raises');

    # Wrong type tag (t != 1) is rejected.
    my $bad = MIME::Base64::encode_base64url('{"t":2,"ns":"x","wid":"y"}', '');
    $bad =~ s/=+\z//;
    my $err2 = T2->dies(sub {
        Temporalio::Nexus::WorkflowHandle->from_token($bad) });
    T2->ok(
        Scalar::Util::blessed($err2) && $err2->isa('Temporalio::Exception::Argument'),
        'a wrong-type token raises Argument',
    );
});

T2->done_testing;
