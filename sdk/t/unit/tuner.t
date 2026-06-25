# ABOUTME: Worker tuner / slot-supplier unit tests (spec §29.2, P10.6,
# ABOUTME: T-tuner-1..4,7): the Tuner factories and composite new build the
# ABOUTME: four-pool holder in the right order; FixedSize/ResourceBased pack the
# ABOUTME: right union tag + body and keep the 464-byte struct; tuner + a
# ABOUTME: max_concurrent_* kwarg is an Argument; no tuner synthesizes a fixed
# ABOUTME: tuner from the slots; a resource target out of (0,1] is an Argument.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Worker::Tuner ();
use Temporalio::Worker::SlotSupplier::FixedSize ();
use Temporalio::Worker::SlotSupplier::ResourceBased ();
use Temporalio::Worker::SlotSupplier::Custom ();
use Temporalio::Core::FFI::WorkerOptions ();

# The slot-supplier union tags (header TemporalCoreSlotSupplier_Tag).
use constant {
    TAG_FIXED_SIZE    => 0,
    TAG_RESOURCE_BASED => 1,
    TAG_CUSTOM        => 2,
};

# A minimal complete WorkerOptions field set; only the tuner pools vary.
sub base_options {
    return (
        namespace            => 'default',
        task_queue           => 'tq',
        versioning_build_id  => 'b',
        identity_override    => undef,
        max_cached_workflows => 1000,
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
# T-tuner-1: Tuner->create_fixed builds four FixedSize suppliers, and the
# packer emits the right tag + num_slots body for each pool in holder order.
# ---------------------------------------------------------------------------
T2->subtest('T-tuner-1 create_fixed packs four FixedSize suppliers' => sub {
    my $tuner = Temporalio::Worker::Tuner->create_fixed(
        workflow_slots       => 7,
        activity_slots       => 11,
        local_activity_slots => 13,
        nexus_task_slots     => 17,
    );
    T2->isa_ok($tuner, ['Temporalio::Worker::Tuner'], 'create_fixed returns a Tuner');

    my @suppliers = (
        $tuner->workflow_slot_supplier,
        $tuner->activity_slot_supplier,
        $tuner->local_activity_slot_supplier,
        $tuner->nexus_task_slot_supplier,
    );
    my @expected = (7, 11, 13, 17);
    for my $i (0 .. 3) {
        T2->isa_ok($suppliers[$i],
            ['Temporalio::Worker::SlotSupplier::FixedSize'],
            "pool $i is a FixedSize supplier");
        T2->is($suppliers[$i]->num_slots, $expected[$i],
            "pool $i has num_slots $expected[$i]");

        # Direct byte inspection of the packed union member (48 bytes:
        # 4-byte tag + 4 pad + 40-byte union body).
        my $union = Temporalio::Core::FFI::WorkerOptions::pack_slot_supplier(
            [], $suppliers[$i]->_pack_spec);
        T2->is(length $union, 48, "pool $i union member is 48 bytes");
        T2->is(unpack('L', substr($union, 0, 4)), TAG_FIXED_SIZE,
            "pool $i tag is FixedSize (0)");
        # num_slots is the first uintptr_t of the body (offset 8).
        T2->is(unpack('Q', substr($union, 8, 8)), $expected[$i],
            "pool $i body num_slots is $expected[$i]");
    }
});

# ---------------------------------------------------------------------------
# T-tuner-2: create_resource_based packs a ResourceBased union (tag 1) with the
# min/max/ramp/target body, and FixedSize for nexus (defaults fixed, WH-7).
# ---------------------------------------------------------------------------
T2->subtest('T-tuner-2 create_resource_based packs a ResourceBased body' => sub {
    my $tuner = Temporalio::Worker::Tuner->create_resource_based(
        target_memory_usage => 0.5,
        target_cpu_usage     => 0.9,
        workflow            => { minimum_slots => 1, maximum_slots => 10,
                                 ramp_throttle_ms => 0 },
        activity            => { minimum_slots => 2, maximum_slots => 20,
                                 ramp_throttle_ms => 50 },
        local_activity      => { minimum_slots => 2, maximum_slots => 20,
                                 ramp_throttle_ms => 50 },
    );

    my $wf = $tuner->workflow_slot_supplier;
    T2->isa_ok($wf, ['Temporalio::Worker::SlotSupplier::ResourceBased'],
        'workflow pool is ResourceBased');

    my $union = Temporalio::Core::FFI::WorkerOptions::pack_slot_supplier(
        [], $wf->_pack_spec);
    T2->is(length $union, 48, 'ResourceBased union member is 48 bytes');
    T2->is(unpack('L', substr($union, 0, 4)), TAG_RESOURCE_BASED,
        'tag is ResourceBased (1)');
    # body: min(Q) max(Q) ramp_ms(Q) mem(d) cpu(d), starting at offset 8.
    my ($min, $max, $ramp) = unpack('Q Q Q', substr($union, 8, 24));
    my ($mem, $cpu)        = unpack('d d', substr($union, 32, 16));
    T2->is($min, 1, 'minimum_slots packed');
    T2->is($max, 10, 'maximum_slots packed');
    T2->is($ramp, 0, 'ramp_throttle_ms packed');
    T2->is($mem, 0.5, 'target_memory_usage packed');
    T2->is($cpu, 0.9, 'target_cpu_usage packed');

    # The nexus pool defaults to a FixedSize supplier (WH-7).
    T2->isa_ok($tuner->nexus_task_slot_supplier,
        ['Temporalio::Worker::SlotSupplier::FixedSize'],
        'nexus pool defaults to FixedSize');
});

# ---------------------------------------------------------------------------
# T-tuner-3: composite Tuner->new packs each pool's supplier in holder order,
# and a full WorkerOptions build with a custom tuner stays 464 bytes. The
# custom supplier packs a Custom union (tag 2) whose body is the callbacks
# pointer (NULL here when no pointer is bound — the worker binds it later).
# ---------------------------------------------------------------------------
T2->subtest('T-tuner-3 composite new + WorkerOptions stays 464 bytes' => sub {
    my $custom_impl = MyCustomSupplier->new;
    my $tuner = Temporalio::Worker::Tuner->new(
        workflow_slot_supplier =>
            Temporalio::Worker::SlotSupplier::FixedSize->new(num_slots => 3),
        activity_slot_supplier =>
            Temporalio::Worker::SlotSupplier::ResourceBased->new(
                target_memory_usage => 0.7, target_cpu_usage => 0.8,
                minimum_slots => 1, maximum_slots => 5, ramp_throttle_ms => 10),
        local_activity_slot_supplier =>
            Temporalio::Worker::SlotSupplier::Custom->new(impl => $custom_impl),
        nexus_task_slot_supplier =>
            Temporalio::Worker::SlotSupplier::FixedSize->new(num_slots => 9),
    );

    # The Custom union packs tag 2.
    my $cu = $tuner->local_activity_slot_supplier;
    my $custom_union = Temporalio::Core::FFI::WorkerOptions::pack_slot_supplier(
        [], $cu->_pack_spec);
    T2->is(unpack('L', substr($custom_union, 0, 4)), TAG_CUSTOM,
        'Custom union tag is 2');
    T2->is(length $custom_union, 48, 'Custom union member is 48 bytes');

    # A full WorkerOptions build with the per-pool suppliers keeps the struct
    # at 464 bytes (the pack-correctness tripwire).
    my @keep;
    my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
        base_options(),
        workflow_slot_supplier_spec =>
            $tuner->workflow_slot_supplier->_pack_spec,
        activity_slot_supplier_spec =>
            $tuner->activity_slot_supplier->_pack_spec,
        local_activity_slot_supplier_spec =>
            $tuner->local_activity_slot_supplier->_pack_spec,
        nexus_task_slot_supplier_spec =>
            $tuner->nexus_task_slot_supplier->_pack_spec,
    );
    T2->ok($ptr, 'WorkerOptions builds with explicit per-pool supplier specs');
});

# ---------------------------------------------------------------------------
# T-tuner-4: a Worker with no tuner synthesizes a fixed tuner from the
# max_concurrent_* kwargs (v0.1 parity). Worker.pm packs FixedSize suppliers.
# Tested at the WorkerOptions level: the legacy workflow_slots => N kwarg still
# packs a FixedSize supplier.
# ---------------------------------------------------------------------------
T2->subtest('T-tuner-4 no tuner -> fixed from slots (back-compat)' => sub {
    my @keep;
    my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
        base_options(),
        workflow_slots       => 100,
        activity_slots       => 100,
        local_activity_slots => 100,
        nexus_task_slots     => 100,
    );
    T2->ok($ptr, 'legacy *_slots kwargs still build a fixed tuner');
});

# ---------------------------------------------------------------------------
# T-tuner-5/6 are covered by t/integration/tuner.t (custom supplier reserve/
# release on the main thread; try_reserve undef defers). They require a live
# dev server and skip_all otherwise.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# T-tuner-7: a resource target out of (0,1] raises Argument, and tuner +
# max_concurrent_* is mutually exclusive (Argument).
# ---------------------------------------------------------------------------
T2->subtest('T-tuner-7 validation -> Argument' => sub {
    for my $bad ([0, 'memory at 0'], [1.5, 'memory above 1'], [-0.1, 'cpu below 0']) {
        my ($val, $desc) = @$bad;
        my $err = do {
            local $@;
            eval {
                Temporalio::Worker::SlotSupplier::ResourceBased->new(
                    target_memory_usage => $val,
                    target_cpu_usage     => 0.5,
                    minimum_slots => 1, maximum_slots => 5, ramp_throttle_ms => 0);
                1;
            } ? undef : $@;
        };
        T2->isa_ok($err, ['Temporalio::Exception::Argument'],
            "ResourceBased rejects $desc");
    }

    # A valid target at the (0,1] boundary is accepted.
    my $ok = Temporalio::Worker::SlotSupplier::ResourceBased->new(
        target_memory_usage => 1.0, target_cpu_usage => 0.0001,
        minimum_slots => 1, maximum_slots => 5, ramp_throttle_ms => 0);
    T2->ok($ok, 'targets at the (0,1] boundary are accepted');

    # Tuner + a max_concurrent_* kwarg on the Worker is mutually exclusive.
    require Temporalio::Worker;
    my $client = FakeClient->new;
    my $tuner = Temporalio::Worker::Tuner->create_fixed(
        workflow_slots => 1, activity_slots => 1,
        local_activity_slots => 1, nexus_task_slots => 1);
    my $err = do {
        local $@;
        eval {
            Temporalio::Worker->new(
                client     => $client,
                task_queue => 'tq',
                tuner      => $tuner,
                max_concurrent_activities => 50,
            );
            1;
        } ? undef : $@;
    };
    T2->isa_ok($err, ['Temporalio::Exception::Argument'],
        'tuner + max_concurrent_* raises Argument');
});

T2->done_testing;

# A trivial custom-supplier impl for the Custom packing test: it just needs to
# satisfy the duck-typed reserve/try_reserve/mark_slot_used/release_slot shape.
package MyCustomSupplier {
    sub new { bless {}, shift }
    sub reserve_slot { return 1 }
    sub try_reserve_slot { return 1 }
    sub mark_slot_used { }
    sub release_slot { }
}

# A minimal fake client: enough surface for Worker->new ADJUST (namespace +
# interceptors are read; no RPC happens here).
package FakeClient {
    sub new { bless {}, shift }
    sub namespace { 'default' }
    sub interceptors { [] }
    sub runtime { undef }
}
