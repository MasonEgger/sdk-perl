# ABOUTME: Worker versioning unit tests (spec §29.1, P10.5, T-wkrver-1..3):
# ABOUTME: DeploymentVersion canonical round-trip; DeploymentOptions/Worker
# ABOUTME: mutual-exclusion + behavior guards; the WorkerOptions versioning
# ABOUTME: packers emit the right union tag/body and keep the 464-byte struct;
# ABOUTME: the :VersioningBehavior attribute parses onto the workflow class.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Worker::DeploymentVersion ();
use Temporalio::Worker::DeploymentOptions ();
use Temporalio::Core::FFI::WorkerOptions ();

# ---------------------------------------------------------------------------
# T-wkrver-1: DeploymentVersion canonical-string round-trip + reject malformed.
# Canonical format "<deployment_name>.<build_id>" (sdk-ruby
# worker_deployment_version.rb): split on the FIRST dot, deployment name has no
# dot, the build_id may contain dots.
# ---------------------------------------------------------------------------
T2->subtest('T-wkrver-1 DeploymentVersion canonical round-trip' => sub {
    my $v = Temporalio::Worker::DeploymentVersion->new(
        deployment_name => 'my-deploy',
        build_id        => 'abc123',
    );
    T2->is($v->deployment_name, 'my-deploy', 'deployment_name accessor');
    T2->is($v->build_id, 'abc123', 'build_id accessor');
    T2->is($v->to_canonical_string, 'my-deploy.abc123',
        'to_canonical_string joins with a dot');

    my $parsed =
        Temporalio::Worker::DeploymentVersion->from_canonical_string('my-deploy.abc123');
    T2->is($parsed->deployment_name, 'my-deploy', 'from_canonical_string name');
    T2->is($parsed->build_id, 'abc123', 'from_canonical_string build_id');

    # The build_id half keeps any later dots (split on the first only).
    my $dotted =
        Temporalio::Worker::DeploymentVersion->from_canonical_string('dep.1.2.3');
    T2->is($dotted->deployment_name, 'dep',
        'from_canonical_string splits on the first dot');
    T2->is($dotted->build_id, '1.2.3', 'build_id keeps trailing dots');

    # Round-trip: parse(to_canonical_string(x)) == x.
    my $round =
        Temporalio::Worker::DeploymentVersion->from_canonical_string(
            $v->to_canonical_string);
    T2->is($round->deployment_name, $v->deployment_name, 'round-trip name');
    T2->is($round->build_id, $v->build_id, 'round-trip build_id');

    # Malformed (no dot) raises Argument.
    my $err = do {
        local $@;
        eval {
            Temporalio::Worker::DeploymentVersion->from_canonical_string('nodot');
            1;
        } ? undef : $@;
    };
    T2->ok($err, 'from_canonical_string("nodot") raises');
    T2->isa_ok($err, ['Temporalio::Exception::Argument'],
        'malformed canonical string is an Argument exception');
});

# ---------------------------------------------------------------------------
# T-wkrver-2: DeploymentOptions constructor + behavior guard.
#   default_versioning_behavior must be one of unspecified/pinned/auto_upgrade,
#   and must stay 'unspecified' unless use_worker_versioning is on (spec §29.1).
# ---------------------------------------------------------------------------
T2->subtest('T-wkrver-2 DeploymentOptions construction + behavior guard' => sub {
    my $version = Temporalio::Worker::DeploymentVersion->new(
        deployment_name => 'd', build_id => 'b');

    my $opts = Temporalio::Worker::DeploymentOptions->new(version => $version);
    T2->is($opts->use_worker_versioning, 0, 'use_worker_versioning defaults off');
    T2->is($opts->default_versioning_behavior, 'unspecified',
        'default_versioning_behavior defaults to unspecified');
    T2->is($opts->default_versioning_behavior_value, 0,
        'unspecified maps to proto enum 0');

    my $on = Temporalio::Worker::DeploymentOptions->new(
        version                     => $version,
        use_worker_versioning       => 1,
        default_versioning_behavior => 'pinned',
    );
    T2->is($on->default_versioning_behavior_value, 1, 'pinned maps to 1');

    my $au = Temporalio::Worker::DeploymentOptions->new(
        version                     => $version,
        use_worker_versioning       => 1,
        default_versioning_behavior => 'auto_upgrade',
    );
    T2->is($au->default_versioning_behavior_value, 2, 'auto_upgrade maps to 2');

    # version is required.
    my $no_version = do {
        local $@;
        eval { Temporalio::Worker::DeploymentOptions->new; 1 } ? undef : $@;
    };
    T2->isa_ok($no_version, ['Temporalio::Exception::Argument'],
        'missing version raises Argument');

    # Unknown behavior string raises Argument.
    my $bad_behavior = do {
        local $@;
        eval {
            Temporalio::Worker::DeploymentOptions->new(
                version                     => $version,
                use_worker_versioning       => 1,
                default_versioning_behavior => 'bogus',
            );
            1;
        } ? undef : $@;
    };
    T2->isa_ok($bad_behavior, ['Temporalio::Exception::Argument'],
        'unknown behavior string raises Argument');

    # A non-unspecified behavior without versioning is invalid (spec §29.1).
    my $behavior_without_versioning = do {
        local $@;
        eval {
            Temporalio::Worker::DeploymentOptions->new(
                version                     => $version,
                use_worker_versioning       => 0,
                default_versioning_behavior => 'pinned',
            );
            1;
        } ? undef : $@;
    };
    T2->isa_ok($behavior_without_versioning, ['Temporalio::Exception::Argument'],
        'pinned default without versioning raises Argument');
});

# ---------------------------------------------------------------------------
# T-wkrver-3: the WorkerOptions packer emits the right union tag/body and the
# struct stays 464 bytes for every versioning strategy.
# ---------------------------------------------------------------------------
T2->subtest('T-wkrver-3 versioning packers keep struct at 464 bytes' => sub {
    # A minimal complete field set; only versioning varies between cases.
    my %base = (
        namespace            => 'default',
        task_queue           => 'tq',
        identity_override    => undef,
        max_cached_workflows => 1000,
        workflow_slots       => 100,
        activity_slots       => 100,
        local_activity_slots => 100,
        nexus_task_slots     => 100,
        enable_workflows         => 1,
        enable_local_activities  => 0,
        enable_remote_activities => 1,
        enable_nexus             => 0,
        sticky_queue_schedule_to_start_timeout_millis => 10000,
        max_heartbeat_throttle_interval_millis        => 60000,
        default_heartbeat_throttle_interval_millis    => 30000,
        max_activities_per_second            => 0,
        max_task_queue_activities_per_second => 0,
        graceful_shutdown_period_millis      => 0,
        workflow_task_poller_simple_maximum  => 5,
        activity_task_poller_simple_maximum  => 5,
        nexus_task_poller_simple_maximum     => 5,
        nonsticky_to_sticky_poll_ratio       => 0.2,
        nondeterminism_as_workflow_fail      => 0,
        nondeterminism_as_workflow_fail_for_types => [],
        plugins         => [],
        storage_drivers => [],
    );

    # The None{build_id} default packs the versioning union with tag 0.
    {
        my @keep;
        my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
            %base, versioning_build_id => 'b1');
        T2->ok($ptr, 'None strategy builds');
    }

    # DeploymentBased: pass a deployment hash; tag 1, struct still 464.
    {
        my @keep;
        my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
            %base,
            versioning_build_id => undef,
            versioning_deployment => {
                deployment_name             => 'dep',
                build_id                    => 'bid',
                use_worker_versioning       => 1,
                default_versioning_behavior => 1,
            });
        T2->ok($ptr, 'DeploymentBased strategy builds at 464 bytes');
    }

    # LegacyBuildIdBased: tag 2, struct still 464.
    {
        my @keep;
        my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
            %base,
            versioning_build_id => undef,
            versioning_legacy_build_id => 'legacy-bid');
        T2->ok($ptr, 'LegacyBuildIdBased strategy builds at 464 bytes');
    }

    # Direct tag inspection of the packed versioning union (offset 32). The
    # tag is the first 4 bytes of the union; the body follows after 4 pad bytes.
    my $none_union = Temporalio::Core::FFI::WorkerOptions::pack_versioning_union(
        [], { build_id => 'b' });
    T2->is(unpack('L', substr($none_union, 0, 4)), 0, 'None union tag is 0');
    T2->is(length $none_union, 48, 'versioning union member is 48 bytes (8 tag+pad + 40 body)');

    my $dep_union = Temporalio::Core::FFI::WorkerOptions::pack_versioning_union(
        [], { deployment => {
            deployment_name => 'd', build_id => 'b',
            use_worker_versioning => 1, default_versioning_behavior => 1 } });
    T2->is(unpack('L', substr($dep_union, 0, 4)), 1, 'DeploymentBased tag is 1');
    T2->is(length $dep_union, 48, 'deployment union member is 48 bytes (8 tag+pad + 40 body)');

    my $legacy_union = Temporalio::Core::FFI::WorkerOptions::pack_versioning_union(
        [], { legacy_build_id => 'l' });
    T2->is(unpack('L', substr($legacy_union, 0, 4)), 2, 'LegacyBuildIdBased tag is 2');
    T2->is(length $legacy_union, 48, 'legacy union member is 48 bytes (8 tag+pad + 40 body)');
});

# ---------------------------------------------------------------------------
# T-wkrver (attribute): :VersioningBehavior parses onto the workflow class and
# is reported through _versioning_behavior / _versioning_behavior_value.
# ---------------------------------------------------------------------------
T2->subtest('T-wkrver :VersioningBehavior attribute parses' => sub {
    require Temporalio::Workflow::Definition;

    my $pkg = 'WfVer::Pinned';
    my $code = <<"PERL";
        use v5.38;
        use warnings;
        use feature 'class';
        no warnings 'experimental::class';
        use Temporalio::Workflow::Definition ();
        class $pkg :isa(Temporalio::Workflow::Definition) {
            method run :Run :VersioningBehavior('pinned') (\$arg) { return 1 }
        }
        1;
PERL
    my $ok = eval "$code";
    T2->ok($ok, "class with :VersioningBehavior('pinned') compiles") or T2->diag($@);
    T2->is($pkg->_versioning_behavior, 'pinned',
        '_versioning_behavior returns the parsed behavior');
    T2->is($pkg->_versioning_behavior_value, 1,
        '_versioning_behavior_value maps pinned to 1');

    # A class with no :VersioningBehavior reports unspecified (0).
    my $plain = 'WfVer::Plain';
    eval <<"PERL2";
        use v5.38;
        use warnings;
        use feature 'class';
        no warnings 'experimental::class';
        use Temporalio::Workflow::Definition ();
        class $plain :isa(Temporalio::Workflow::Definition) {
            method run :Run (\$arg) { return 1 }
        }
        1;
PERL2
    T2->is($plain->_versioning_behavior_value, 0,
        'a class with no behavior reports unspecified (0)');

    # An invalid behavior token raises at compile time.
    my $bad = eval <<"PERL3";
        use v5.38;
        use warnings;
        use feature 'class';
        no warnings 'experimental::class';
        use Temporalio::Workflow::Definition ();
        class WfVer::Bad :isa(Temporalio::Workflow::Definition) {
            method run :Run :VersioningBehavior('bogus') (\$arg) { return 1 }
        }
        1;
PERL3
    T2->ok(!$bad, ':VersioningBehavior("bogus") fails to compile');
    T2->like($@, qr/versioning/i, 'error mentions versioning');
});

T2->done_testing;
