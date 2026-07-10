# ABOUTME: spec R97 (parity audit client finding 5): the high-level client
# ABOUTME: deliberately omits the three deprecated legacy build-id RPCs
# ABOUTME: (Python client/_client.py:2770,2801,2832, all ".. deprecated::"),
# ABOUTME: the supported deployment-versioning replacement is green, and the
# ABOUTME: raw workflow_service escape hatch (R91) still reaches the rpcs.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use lib 'lib';

use Temporalio::Client ();
use Temporalio::Client::WorkflowService ();
use Temporalio::Common::VersioningOverride ();
use Temporalio::Worker::DeploymentOptions ();
use Temporalio::Worker::DeploymentVersion ();

my @LEGACY = qw(
    update_worker_build_id_compatibility
    get_worker_build_id_compatibility
    get_worker_task_reachability
);

# The raw_service.t FakeConnection precedent: a classic blessed-hash double
# so the generated rpc methods can install without a live connection.
package FakeConnection {
    sub new { return bless {}, shift }
    sub rpc_call { require Future; return Future->done('FAKE') }
}

# ---------------------------------------------------------------------------
# The deliberate omission (spec R97, resolved DOC-ONLY): the high-level
# client does not port the legacy build-id surface. All three are deprecated
# in Python and superseded by deployment-based versioning.
# ---------------------------------------------------------------------------
T2->subtest('high-level client omits the legacy build-id RPCs' => sub {
    for my $api (@LEGACY) {
        T2->ok(!Temporalio::Client->can($api),
            "Temporalio::Client has no $api method (deliberate, spec R97)");
    }
});

# ---------------------------------------------------------------------------
# The escape hatch: the R91 raw WorkflowService handle generates its methods
# from the vendored proto service descriptor, which still lists the three
# legacy rpcs, so callers who need them against an older server can reach
# them without the high-level surface.
# ---------------------------------------------------------------------------
T2->subtest('raw workflow_service escape hatch still reaches them' => sub {
    my $wf = Temporalio::Client::WorkflowService->new(
        connection => FakeConnection->new);
    for my $api (@LEGACY) {
        T2->ok($wf->can($api),
            "raw WorkflowService handle generates $api from the descriptor");
    }
});

# ---------------------------------------------------------------------------
# The supported replacement is exercised and green: DeploymentVersion,
# DeploymentOptions (worker side, spec section 29.1), and the per-execution
# VersioningOverride start option (spec R37).
# ---------------------------------------------------------------------------
T2->subtest('deployment-based versioning path is green' => sub {
    my $version = Temporalio::Worker::DeploymentVersion->new(
        deployment_name => 'my-deploy',
        build_id        => 'abc123',
    );
    T2->is($version->to_canonical_string, 'my-deploy.abc123',
        'DeploymentVersion canonical string');

    my $opts = Temporalio::Worker::DeploymentOptions->new(
        version                     => $version,
        use_worker_versioning       => 1,
        default_versioning_behavior => 'auto_upgrade',
    );
    T2->is($opts->use_worker_versioning, 1, 'DeploymentOptions versioning on');
    T2->is($opts->default_versioning_behavior_value, 2,
        'auto_upgrade maps to the proto VersioningBehavior enum value 2');

    my $pinned = Temporalio::Common::VersioningOverride->pinned($version);
    my $proto  = $pinned->to_proto;
    T2->is($proto->behavior, 1, 'pinned override proto behavior');
    T2->is($proto->pinned_version, 'my-deploy.abc123',
        'pinned override carries the canonical version string');

    my $auto = Temporalio::Common::VersioningOverride->auto_upgrade;
    T2->is($auto->to_proto->behavior, 2, 'auto_upgrade override proto behavior');
});

T2->done_testing;
