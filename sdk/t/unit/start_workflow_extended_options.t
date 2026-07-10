# ABOUTME: Unit tests for the spec R37 (finding A7) start_workflow extended
# ABOUTME: options: static_summary/static_details -> the request user_metadata
# ABOUTME: payloads and versioning_override -> its proto field, never silently dropped.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Client ();
use Temporalio::Common::VersioningOverride ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Worker::DeploymentVersion ();

Temporalio::Core::Proto->load;

# A client built without a live connection: the request builder never touches
# the connection pointer, only namespace/identity/data_converter (the
# start_workflow_request.t harness).
sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-test',
        identity       => 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# ---------------------------------------------------------------------------
# static_summary / static_details -> request user_metadata (sdk-python
# client/_helpers.py _encode_user_metadata: each string encodes to a single
# json/plain Payload on temporal.api.sdk.v1.UserMetadata).
# ---------------------------------------------------------------------------
T2->subtest('static_summary and static_details land in user_metadata' => sub {
    my $req = make_client->_build_start_workflow_request(
        'W', [],
        id             => 'wf-meta',
        task_queue     => 'q',
        static_summary => 'runs the nightly sync',
        static_details => 'longer form details about the nightly sync',
    )->get;

    my $metadata = $req->user_metadata;
    T2->ok(defined $metadata, 'user_metadata set on the request');
    T2->is($metadata->summary->metadata->{encoding}, 'json/plain',
        'summary payload json/plain');
    T2->is($metadata->summary->data, '"runs the nightly sync"',
        'summary data (JSON string)');
    T2->is($metadata->details->metadata->{encoding}, 'json/plain',
        'details payload json/plain');
    T2->is($metadata->details->data,
        '"longer form details about the nightly sync"',
        'details data (JSON string)');

    # round-trips on the wire (UserMetadata is field 23 on the request)
    my $back = (ref $req)->decode($req->encode);
    T2->is($back->user_metadata->summary->data, '"runs the nightly sync"',
        'user_metadata survives encode/decode');
});

T2->subtest('summary alone leaves details unset' => sub {
    my $req = make_client->_build_start_workflow_request(
        'W', [],
        id             => 'wf-meta-s',
        task_queue     => 'q',
        static_summary => 'just a summary',
    )->get;

    T2->ok(defined $req->user_metadata, 'user_metadata set');
    T2->is($req->user_metadata->summary->data, '"just a summary"',
        'summary encoded');
    T2->ok(!defined $req->user_metadata->details, 'details unset');
});

T2->subtest('a pre-encoded Payload summary passes through untouched' => sub {
    # sdk-python _encode_user_metadata accepts str | Payload; a Payload is
    # placed on UserMetadata as-is (no double-encode).
    my $Payload = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.Payload');
    my $payload = $Payload->new({
        metadata => { encoding => 'json/plain' },
        data     => '"pre-encoded"',
    });
    my $req = make_client->_build_start_workflow_request(
        'W', [],
        id             => 'wf-meta-p',
        task_queue     => 'q',
        static_summary => $payload,
    )->get;

    T2->is($req->user_metadata->summary->data, '"pre-encoded"',
        'payload data untouched (not re-encoded)');
});

T2->subtest('omitting the extended options leaves the fields unset' => sub {
    my $req = make_client->_build_start_workflow_request(
        'W', [], id => 'wf-none', task_queue => 'q',
    )->get;

    T2->ok(!defined $req->user_metadata, 'no user_metadata');
    T2->ok(!defined $req->versioning_override, 'no versioning_override');
});

# ---------------------------------------------------------------------------
# versioning_override -> the request versioning_override field (sdk-python
# common.py PinnedVersioningOverride/AutoUpgradeVersioningOverride._to_proto,
# including the deprecated behavior/pinned_version fields for compatibility).
# ---------------------------------------------------------------------------
T2->subtest('pinned versioning_override lands on the request' => sub {
    my $version = Temporalio::Worker::DeploymentVersion->new(
        deployment_name => 'my-deploy',
        build_id        => 'build.7',
    );
    my $req = make_client->_build_start_workflow_request(
        'W', [],
        id                  => 'wf-pin',
        task_queue          => 'q',
        versioning_override =>
            Temporalio::Common::VersioningOverride->pinned($version),
    )->get;

    my $vo = $req->versioning_override;
    T2->ok(defined $vo, 'versioning_override set');
    T2->is($vo->behavior, 1, 'deprecated behavior VERSIONING_BEHAVIOR_PINNED');
    T2->is($vo->pinned_version, 'my-deploy.build.7',
        'deprecated pinned_version canonical string');
    T2->is($vo->pinned->behavior, 1,
        'pinned.behavior PINNED_OVERRIDE_BEHAVIOR_PINNED');
    T2->is($vo->pinned->version->deployment_name, 'my-deploy',
        'pinned.version.deployment_name');
    T2->is($vo->pinned->version->build_id, 'build.7',
        'pinned.version.build_id');

    # round-trips on the wire (VersioningOverride is field 25 on the request)
    my $back = (ref $req)->decode($req->encode);
    T2->is($back->versioning_override->pinned_version, 'my-deploy.build.7',
        'versioning_override survives encode/decode');
});

T2->subtest('auto_upgrade versioning_override lands on the request' => sub {
    my $req = make_client->_build_start_workflow_request(
        'W', [],
        id                  => 'wf-auto',
        task_queue          => 'q',
        versioning_override =>
            Temporalio::Common::VersioningOverride->auto_upgrade,
    )->get;

    my $vo = $req->versioning_override;
    T2->ok(defined $vo, 'versioning_override set');
    T2->is($vo->behavior, 2,
        'deprecated behavior VERSIONING_BEHAVIOR_AUTO_UPGRADE');
    T2->ok($vo->auto_upgrade, 'auto_upgrade oneof arm set');
});

# ---------------------------------------------------------------------------
# Typed rejection instead of silent dropping (the R37 contract).
# ---------------------------------------------------------------------------
T2->subtest('a non-VersioningOverride value raises Argument pre-RPC' => sub {
    my $err = T2->dies(sub {
        make_client->_build_start_workflow_request(
            'W', [],
            id                  => 'wf-bad',
            task_queue          => 'q',
            versioning_override => 'pinned',
        )->get;
    });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'bad versioning_override -> Argument, not silently dropped');
    T2->like("$err", qr/versioning_override/, 'message names the option');
});

T2->subtest('pinned() requires a DeploymentVersion' => sub {
    my $err = T2->dies(sub {
        Temporalio::Common::VersioningOverride->pinned('my-deploy.build.7');
    });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'pinned(non-DeploymentVersion) -> Argument');
});

# ---------------------------------------------------------------------------
# The shared populator carries the options into SignalWithStart too.
# ---------------------------------------------------------------------------
T2->subtest('signal_with_start carries the extended options' => sub {
    my $req = make_client->_build_signal_with_start_workflow_request(
        'W', [],
        id                  => 'wf-sws',
        task_queue          => 'q',
        signal              => 'greet',
        static_summary      => 'sws summary',
        versioning_override =>
            Temporalio::Common::VersioningOverride->auto_upgrade,
    )->get;

    T2->is($req->user_metadata->summary->data, '"sws summary"',
        'user_metadata on the SignalWithStart request');
    T2->is($req->versioning_override->behavior, 2,
        'versioning_override on the SignalWithStart request');
});

T2->done_testing;
