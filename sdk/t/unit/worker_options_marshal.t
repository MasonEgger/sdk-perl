# ABOUTME: Risk-spike-3 marshalling test (plan P0.10): Perl hand-packs the full
# ABOUTME: TemporalCoreWorkerOptions tree; the shim echo verifies every field.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Core::FFI ();

# The shim's temporalio_perl_bridge_debug_worker_options parses the struct it
# receives (via layout-mirror repr(C) definitions of the pinned C header) and
# returns a newline-delimited field=value summary. If any Perl-side offset,
# size, padding byte, or union tag were wrong, the echoed values could not
# all match what Perl set — this is the empirical layout proof closing spec
# section 11 risk spike 3, with no server or live worker needed.

T2->subtest('module loads' => sub {
    my $loaded = eval { require Temporalio::Core::FFI::WorkerOptions; 1 };
    T2->ok($loaded, 'require Temporalio::Core::FFI::WorkerOptions succeeds')
        or T2->diag($@);
});

sub echo_summary ($ptr) {
    my $raw = Temporalio::Core::FFI::debug_worker_options($ptr);
    defined $raw or T2->bail_out('debug_worker_options returned NULL');
    my $summary = Temporalio::Core::FFI::ffi()->cast('opaque' => 'string', $raw);
    Temporalio::Core::FFI::string_free($raw);
    return $summary;
}

# field=value lines into a hashref; values may themselves contain '='
# (e.g. "autoscaling(min=1,...)"), so split each line at the FIRST '='.
sub parse_summary ($summary) {
    return {
        map { my ($key, $value) = split /=/, $_, 2; ($key => $value) }
        split /\n/, $summary,
    };
}

T2->subtest('spec 8.1 v0.1 configuration echoes field-for-field' => sub {
    my $keep = [];
    my $ptr  = Temporalio::Core::FFI::WorkerOptions::build($keep,
        namespace            => 'default-ns',
        task_queue           => 'spike-tq',
        versioning_build_id  => 'b1',
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
        max_activities_per_second                     => 0,
        max_task_queue_activities_per_second          => 0,
        graceful_shutdown_period_millis               => 0,

        workflow_task_poller_simple_maximum => 5,
        activity_task_poller_simple_maximum => 5,
        nexus_task_poller_simple_maximum    => 5,
        nonsticky_to_sticky_poll_ratio      => 0.2,

        nondeterminism_as_workflow_fail           => 0,
        nondeterminism_as_workflow_fail_for_types => [],
        plugins                                   => [],
        storage_drivers                           => [],
    );
    T2->ok(defined $ptr, 'build returns a pointer');

    my $echoed = parse_summary(echo_summary($ptr));
    T2->is($echoed, {
        'namespace'                          => 'default-ns',
        'task_queue'                         => 'spike-tq',
        'versioning_strategy.tag'            => 'None',
        'versioning_strategy.none.build_id'  => 'b1',
        'identity_override'                  => '<null>',
        'max_cached_workflows'               => '1000',
        'tuner.workflow_slot_supplier'       => 'FixedSize(100)',
        'tuner.activity_slot_supplier'       => 'FixedSize(100)',
        'tuner.local_activity_slot_supplier' => 'FixedSize(100)',
        'tuner.nexus_task_slot_supplier'     => 'FixedSize(100)',
        'task_types.enable_workflows'        => 'true',
        'task_types.enable_local_activities' => 'false',
        'task_types.enable_remote_activities' => 'true',
        'task_types.enable_nexus'            => 'false',
        'sticky_queue_schedule_to_start_timeout_millis' => '10000',
        'max_heartbeat_throttle_interval_millis'        => '60000',
        'default_heartbeat_throttle_interval_millis'    => '30000',
        'max_activities_per_second'            => '0',
        'max_task_queue_activities_per_second' => '0',
        'graceful_shutdown_period_millis'      => '0',
        'workflow_task_poller_behavior'  => 'simple_maximum(5)',
        'nonsticky_to_sticky_poll_ratio' => '0.2',
        'activity_task_poller_behavior'  => 'simple_maximum(5)',
        'nexus_task_poller_behavior'     => 'simple_maximum(5)',
        'nondeterminism_as_workflow_fail' => 'false',
        'nondeterminism_as_workflow_fail_for_types' => '[]',
        'plugins'         => '[]',
        'storage_drivers' => '[]',
    }, 'every echoed field matches what Perl packed');
});

# Identical values in sibling fields (four 100s, three 5s) cannot catch
# transposed offsets — a second configuration with pairwise-distinct values
# in every slot pins each field to its exact location.
T2->subtest('pairwise-distinct values pin every field offset' => sub {
    my $keep = [];
    my $ptr  = Temporalio::Core::FFI::WorkerOptions::build($keep,
        namespace            => 'offset-ns',
        task_queue           => 'offset-tq',
        versioning_build_id  => 'build-xyz',
        identity_override    => 'perl-spike@host',
        max_cached_workflows => 42,

        workflow_slots       => 7,
        activity_slots       => 11,
        local_activity_slots => 13,
        nexus_task_slots     => 17,

        enable_workflows         => 0,
        enable_local_activities  => 1,
        enable_remote_activities => 0,
        enable_nexus             => 1,

        sticky_queue_schedule_to_start_timeout_millis => 11111,
        max_heartbeat_throttle_interval_millis        => 22222,
        default_heartbeat_throttle_interval_millis    => 33333,
        max_activities_per_second                     => 1.5,
        max_task_queue_activities_per_second          => 2.25,
        graceful_shutdown_period_millis               => 5000,

        workflow_task_poller_simple_maximum => 5,
        activity_task_poller_simple_maximum => 6,
        nexus_task_poller_simple_maximum    => 7,
        nonsticky_to_sticky_poll_ratio      => 0.25,

        nondeterminism_as_workflow_fail           => 1,
        nondeterminism_as_workflow_fail_for_types => [ 'My::Err', 'Other::Err' ],
        plugins                                   => ['p1'],
        storage_drivers                           => [ 's1', 's2' ],
    );

    my $echoed = parse_summary(echo_summary($ptr));
    T2->is($echoed, {
        'namespace'                          => 'offset-ns',
        'task_queue'                         => 'offset-tq',
        'versioning_strategy.tag'            => 'None',
        'versioning_strategy.none.build_id'  => 'build-xyz',
        'identity_override'                  => 'perl-spike@host',
        'max_cached_workflows'               => '42',
        'tuner.workflow_slot_supplier'       => 'FixedSize(7)',
        'tuner.activity_slot_supplier'       => 'FixedSize(11)',
        'tuner.local_activity_slot_supplier' => 'FixedSize(13)',
        'tuner.nexus_task_slot_supplier'     => 'FixedSize(17)',
        'task_types.enable_workflows'        => 'false',
        'task_types.enable_local_activities' => 'true',
        'task_types.enable_remote_activities' => 'false',
        'task_types.enable_nexus'            => 'true',
        'sticky_queue_schedule_to_start_timeout_millis' => '11111',
        'max_heartbeat_throttle_interval_millis'        => '22222',
        'default_heartbeat_throttle_interval_millis'    => '33333',
        'max_activities_per_second'            => '1.5',
        'max_task_queue_activities_per_second' => '2.25',
        'graceful_shutdown_period_millis'      => '5000',
        'workflow_task_poller_behavior'  => 'simple_maximum(5)',
        'nonsticky_to_sticky_poll_ratio' => '0.25',
        'activity_task_poller_behavior'  => 'simple_maximum(6)',
        'nexus_task_poller_behavior'     => 'simple_maximum(7)',
        'nondeterminism_as_workflow_fail' => 'true',
        'nondeterminism_as_workflow_fail_for_types' => '[My::Err,Other::Err]',
        'plugins'         => '[p1]',
        'storage_drivers' => '[s1,s2]',
    }, 'every field lands at its exact offset');
});

T2->done_testing;
