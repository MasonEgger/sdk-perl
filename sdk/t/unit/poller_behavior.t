# ABOUTME: Autoscaling-poller unit tests (spec §29.3, P10.7, T-poller-1..4):
# ABOUTME: SimpleMaximum packs (ptr,NULL) at offset 352 keeping the 464-byte
# ABOUTME: struct; Autoscaling packs (NULL,ptr) with a 3xu64 body; an explicit
# ABOUTME: legacy max_concurrent_workflow_task_polls overrides a passed
# ABOUTME: Autoscaling with SimpleMaximum, and without it the Autoscaling is
# ABOUTME: preserved; construction and resolution validation raise Argument.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Worker::PollerBehavior::SimpleMaximum ();
use Temporalio::Worker::PollerBehavior::Autoscaling ();
use Temporalio::Core::FFI::WorkerOptions ();

# A minimal complete WorkerOptions field set; only the poller fields vary. The
# legacy *_poller_simple_maximum defaults stand in for whichever pool is not
# being driven by an explicit behavior spec under test.
sub base_options {
    return (
        namespace            => 'default',
        task_queue           => 'tq',
        versioning_build_id  => 'b',
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
}

# ---------------------------------------------------------------------------
# T-poller-1: SimpleMaximum packs the TemporalCorePollerBehavior two-pointer
# struct as (simple_ptr, NULL): the first pointer is non-NULL and dereferences
# to the maximum; the second (autoscaling) pointer is NULL. The outer struct is
# 16 bytes, so a full WorkerOptions build still totals 464 bytes with
# nonsticky_to_sticky_poll_ratio intact.
# ---------------------------------------------------------------------------
T2->subtest('T-poller-1 SimpleMaximum packs (simple_ptr, NULL)' => sub {
    my $behavior = Temporalio::Worker::PollerBehavior::SimpleMaximum->new(
        maximum => 5);
    T2->is($behavior->maximum, 5, 'maximum stored');
    T2->is($behavior->_pack_spec, { simple_maximum => 5 },
        '_pack_spec is { simple_maximum => 5 }');

    my $struct = Temporalio::Core::FFI::WorkerOptions::pack_poller_behavior(
        [], $behavior->_pack_spec);
    T2->is(length $struct, 16, 'poller struct is 16 bytes (two pointers)');
    my ($simple_ptr, $auto_ptr) = unpack('Q Q', $struct);
    T2->ok($simple_ptr != 0, 'simple_maximum pointer is non-NULL');
    T2->is($auto_ptr, 0, 'autoscaling pointer is NULL');

    # A full WorkerOptions build with an explicit SimpleMaximum behavior spec
    # keeps the struct at 464 bytes (the pack-correctness tripwire). The default
    # *_poller_simple_maximum kwargs are ignored when a spec is present.
    my @keep;
    my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
        base_options(),
        workflow_task_poller_behavior_spec => $behavior->_pack_spec,
        activity_task_poller_behavior_spec => $behavior->_pack_spec,
        nexus_task_poller_behavior_spec    => $behavior->_pack_spec,
    );
    T2->ok($ptr, 'WorkerOptions builds with explicit SimpleMaximum poller specs');

    # The legacy *_poller_simple_maximum kwargs still build (back-compat).
    my @keep2;
    my $ptr2 = Temporalio::Core::FFI::WorkerOptions::build(\@keep2, base_options());
    T2->ok($ptr2, 'legacy *_poller_simple_maximum kwargs still build');
});

# ---------------------------------------------------------------------------
# T-poller-2: Autoscaling packs the struct as (NULL, autoscaling_ptr); the
# autoscaling sub-struct is the 3xu64 body [minimum, maximum, initial].
# ---------------------------------------------------------------------------
T2->subtest('T-poller-2 Autoscaling packs (NULL, autoscaling_ptr)' => sub {
    my $behavior = Temporalio::Worker::PollerBehavior::Autoscaling->new(
        minimum => 2, maximum => 50, initial => 10);
    T2->is([$behavior->minimum, $behavior->maximum, $behavior->initial],
        [2, 50, 10], 'minimum/maximum/initial stored');
    T2->is($behavior->_pack_spec,
        { autoscaling => { minimum => 2, maximum => 50, initial => 10 } },
        '_pack_spec carries the autoscaling body');

    # Keep the sub-struct alive so we can dereference and inspect it.
    my @keep;
    my $struct = Temporalio::Core::FFI::WorkerOptions::pack_poller_behavior(
        \@keep, $behavior->_pack_spec);
    T2->is(length $struct, 16, 'poller struct is 16 bytes (two pointers)');
    my ($simple_ptr, $auto_ptr) = unpack('Q Q', $struct);
    T2->is($simple_ptr, 0, 'simple_maximum pointer is NULL');
    T2->ok($auto_ptr != 0, 'autoscaling pointer is non-NULL');

    # Dereference the autoscaling sub-struct (3 x uintptr_t) from kept memory.
    require FFI::Platypus::Buffer;
    my $body = FFI::Platypus::Buffer::buffer_to_scalar($auto_ptr, 24);
    my ($min, $max, $init) = unpack('Q Q Q', $body);
    T2->is([$min, $max, $init], [2, 50, 10],
        'autoscaling body is [minimum, maximum, initial]');

    # Defaults match the mature SDKs (minimum=1, maximum=100, initial=5).
    my $default = Temporalio::Worker::PollerBehavior::Autoscaling->new;
    T2->is([$default->minimum, $default->maximum, $default->initial],
        [1, 100, 5], 'Autoscaling defaults are 1/100/5');

    # A full WorkerOptions build with an autoscaling workflow poller stays 464.
    my @keep2;
    my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep2,
        base_options(),
        workflow_task_poller_behavior_spec => $behavior->_pack_spec,
    );
    T2->ok($ptr, 'WorkerOptions builds with an autoscaling workflow poller');
});

# ---------------------------------------------------------------------------
# T-poller-3: an explicit legacy max_concurrent_workflow_task_polls overrides a
# passed Autoscaling behavior with SimpleMaximum(that) (Python override model);
# without the legacy kwarg the Autoscaling is preserved. Tested through
# Worker->_poller_behavior_options.
# ---------------------------------------------------------------------------
T2->subtest('T-poller-3 legacy poll count overrides Autoscaling' => sub {
    require Temporalio::Worker;

    # Override: Autoscaling behavior + explicit legacy count -> SimpleMaximum.
    my $w1 = Temporalio::Worker->new(
        client     => FakeClient->new,
        task_queue => 'tq',
        workflow_task_poller_behavior =>
            Temporalio::Worker::PollerBehavior::Autoscaling->new(
                minimum => 1, maximum => 10, initial => 3),
        max_concurrent_workflow_task_polls => 8,
    );
    my %opts1 = $w1->_poller_behavior_options;
    T2->is($opts1{workflow_task_poller_behavior_spec},
        { simple_maximum => 8 },
        'explicit legacy count overrides Autoscaling with SimpleMaximum(8)');

    # No legacy count: the Autoscaling behavior is preserved.
    my $w2 = Temporalio::Worker->new(
        client     => FakeClient->new,
        task_queue => 'tq',
        workflow_task_poller_behavior =>
            Temporalio::Worker::PollerBehavior::Autoscaling->new(
                minimum => 2, maximum => 20, initial => 5),
    );
    my %opts2 = $w2->_poller_behavior_options;
    T2->is($opts2{workflow_task_poller_behavior_spec},
        { autoscaling => { minimum => 2, maximum => 20, initial => 5 } },
        'without a legacy count the Autoscaling behavior is preserved');

    # Nexus has no legacy equivalent: its behavior is taken directly, defaulting
    # to SimpleMaximum(5) when unset.
    T2->is($opts2{nexus_task_poller_behavior_spec}, { simple_maximum => 5 },
        'nexus poller defaults to SimpleMaximum(5)');

    # Default (no behavior, no legacy count) -> SimpleMaximum(5) everywhere.
    my $w3 = Temporalio::Worker->new(
        client => FakeClient->new, task_queue => 'tq');
    my %opts3 = $w3->_poller_behavior_options;
    T2->is($opts3{workflow_task_poller_behavior_spec}, { simple_maximum => 5 },
        'default workflow poller is SimpleMaximum(5)');
    T2->is($opts3{activity_task_poller_behavior_spec}, { simple_maximum => 5 },
        'default activity poller is SimpleMaximum(5)');
});

# ---------------------------------------------------------------------------
# T-poller-4: validation raises Argument. SimpleMaximum(0) at construction;
# Autoscaling(minimum > maximum) and (initial out of [min,max]) at construction;
# a SimpleMaximum(1) resolved for the workflow-task pool (core requires >= 2);
# a non-behavior object passed to a poller kwarg.
# ---------------------------------------------------------------------------
T2->subtest('T-poller-4 validation -> Argument' => sub {
    require Temporalio::Worker;

    my $argument = sub ($code, $desc) {
        my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
        T2->isa_ok($err, ['Temporalio::Exception::Argument'], $desc);
    };

    $argument->(sub {
        Temporalio::Worker::PollerBehavior::SimpleMaximum->new(maximum => 0);
    }, 'SimpleMaximum(maximum => 0) rejected');

    $argument->(sub {
        Temporalio::Worker::PollerBehavior::Autoscaling->new(
            minimum => 5, maximum => 2, initial => 3);
    }, 'Autoscaling minimum > maximum rejected');

    $argument->(sub {
        Temporalio::Worker::PollerBehavior::Autoscaling->new(
            minimum => 1, maximum => 10, initial => 20);
    }, 'Autoscaling initial > maximum rejected');

    $argument->(sub {
        Temporalio::Worker::PollerBehavior::Autoscaling->new(
            minimum => 0, maximum => 10, initial => 5);
    }, 'Autoscaling minimum < 1 rejected');

    # A SimpleMaximum(1) for the workflow-task pool fails core's >= 2 constraint
    # at resolution time (Worker->_poller_behavior_options).
    $argument->(sub {
        my $w = Temporalio::Worker->new(
            client     => FakeClient->new,
            task_queue => 'tq',
            workflow_task_poller_behavior =>
                Temporalio::Worker::PollerBehavior::SimpleMaximum->new(maximum => 1),
        );
        $w->_poller_behavior_options;
    }, 'SimpleMaximum(1) for the workflow pool rejected (core requires >= 2)');

    # SimpleMaximum(1) is fine for the activity pool.
    my $w_ok = Temporalio::Worker->new(
        client     => FakeClient->new,
        task_queue => 'tq',
        activity_task_poller_behavior =>
            Temporalio::Worker::PollerBehavior::SimpleMaximum->new(maximum => 1),
    );
    my %opts = $w_ok->_poller_behavior_options;
    T2->is($opts{activity_task_poller_behavior_spec}, { simple_maximum => 1 },
        'SimpleMaximum(1) accepted for the activity pool');

    # A non-behavior object passed to a poller kwarg is an Argument (caught in
    # ADJUST).
    $argument->(sub {
        Temporalio::Worker->new(
            client     => FakeClient->new,
            task_queue => 'tq',
            nexus_task_poller_behavior => 'not-a-behavior',
        );
    }, 'a non-behavior poller kwarg is rejected');
});

T2->done_testing;

# A minimal fake client: enough surface for Worker->new ADJUST (namespace +
# interceptors are read; no RPC happens here).
package FakeClient {
    sub new { bless {}, shift }
    sub namespace { 'default' }
    sub interceptors { [] }
    sub runtime { undef }
}
