# ABOUTME: Hand-packs the TemporalCoreWorkerOptions tree with pack() per the
# ABOUTME: pinned header layout; Platypus records cannot express its unions.
use v5.38;
use warnings;

package Temporalio::Core::FFI::WorkerOptions;

our $VERSION = '0.1.0';

use Temporalio::Core::FFI ();

# Mechanism (spec section 11 risk spike 3, CLOSED): TemporalCoreWorkerOptions
# embeds tagged unions BY VALUE — TemporalCoreWorkerVersioningStrategy and
# the four TemporalCoreSlotSupplier members of TemporalCoreTunerHolder —
# which FFI::Platypus::Record cannot express (no unions, no nested records).
# This module therefore hand-packs the struct bytes with pack(), the
# spec-sanctioned fallback: we control the pinned header version, so the
# layout is stable per release.
#
# Layout assumptions: x86-64 SysV ABI (LP64, little-endian), transcribed from
# temporal-sdk-core-c-bridge.h at the pinned sdk-rust tag. Every offset is
# verified empirically by t/unit/worker_options_marshal.t against the shim's
# debug_worker_options echo, which parses the buffer through repr(C) mirrors
# of the bridge's own struct definitions. Bumping the sdk-rust pin requires
# re-running that test (plan P0.10).
#
# v0.1 always passes versioning None{build_id}, four FixedSize slot
# suppliers, and simple-maximum poller behaviors (spec section 8.1);
# the other union variants are Phase 6+ and intentionally unsupported here.

# C-enum tag values, in header declaration order:
#   TemporalCoreWorkerVersioningStrategy_Tag: None, DeploymentBased,
#     LegacyBuildIdBased
#   TemporalCoreSlotSupplier_Tag: FixedSize, ResourceBased, Custom
use constant {
    VERSIONING_TAG_NONE          => 0,
    SLOT_SUPPLIER_TAG_FIXED_SIZE => 0,
};

# sizeof() of each by-value union = its largest member:
#   versioning union: TemporalCoreWorkerDeploymentOptions (40 bytes)
#   slot-supplier union: TemporalCoreResourceBasedSlotSupplier (40 bytes)
# and the full struct: 464 bytes (used as a pack-correctness tripwire).
use constant {
    VERSIONING_UNION_SIZE    => 40,
    SLOT_SUPPLIER_UNION_SIZE => 40,
    STRUCT_SIZE              => 464,
};

# Every field is required (pass undef/[] explicitly); a struct builder with
# hidden defaults would let an omitted field silently become zero bytes.
my @FIELDS = qw(
    namespace
    task_queue
    versioning_build_id
    identity_override
    max_cached_workflows
    workflow_slots
    activity_slots
    local_activity_slots
    nexus_task_slots
    enable_workflows
    enable_local_activities
    enable_remote_activities
    enable_nexus
    sticky_queue_schedule_to_start_timeout_millis
    max_heartbeat_throttle_interval_millis
    default_heartbeat_throttle_interval_millis
    max_activities_per_second
    max_task_queue_activities_per_second
    graceful_shutdown_period_millis
    workflow_task_poller_simple_maximum
    activity_task_poller_simple_maximum
    nexus_task_poller_simple_maximum
    nonsticky_to_sticky_poll_ratio
    nondeterminism_as_workflow_fail
    nondeterminism_as_workflow_fail_for_types
    plugins
    storage_drivers
);
my %KNOWN_FIELD = map { $_ => 1 } @FIELDS;

sub _throw_argument ($message) {
    require Temporalio::Exception::Argument;
    Temporalio::Exception::Argument->throw(message => $message);
}

# TemporalCoreByteArrayRef { const uint8_t *data; size_t size; } — undef
# packs as a NULL ref. The string copy lives on @$keep.
sub _pack_byte_array_ref ($keep, $string) {
    my ($data, $size) = Temporalio::Core::FFI::keep_buffer($keep, $string);
    return pack('Q Q', $data // 0, $size);
}

# cbindgen tagged-union layout: 4-byte C-enum tag, 4 padding bytes (every
# variant here is 8-aligned), then the active variant zero-padded to the
# union size so the next struct member lands at its true offset.
sub _pack_tagged_union ($tag, $variant, $union_size) {
    return pack('L x4', $tag)
         . $variant
         . ("\0" x ($union_size - length $variant));
}

# TemporalCoreWorkerVersioningStrategy as None{build_id} (spec section 8.1).
sub _pack_versioning_none ($keep, $build_id) {
    return _pack_tagged_union(
        VERSIONING_TAG_NONE,
        _pack_byte_array_ref($keep, $build_id),
        VERSIONING_UNION_SIZE,
    );
}

# TemporalCoreSlotSupplier as FixedSize{num_slots}.
sub _pack_fixed_size_slot_supplier ($num_slots) {
    return _pack_tagged_union(
        SLOT_SUPPLIER_TAG_FIXED_SIZE,
        pack('Q', $num_slots),
        SLOT_SUPPLIER_UNION_SIZE,
    );
}

# TemporalCorePollerBehavior holds POINTERS to its variants; pack the
# TemporalCorePollerBehaviorSimpleMaximum struct (one uintptr_t) into kept
# memory and reference it, with autoscaling NULL.
sub _pack_simple_maximum_poller ($keep, $maximum) {
    my ($struct_ptr) = Temporalio::Core::FFI::keep_buffer($keep, pack('Q', $maximum));
    return pack('Q Q', $struct_ptr, 0);
}

# TemporalCoreByteArrayRefArray { const TemporalCoreByteArrayRef *data;
# size_t size; } — element refs are packed contiguously into kept memory.
sub _pack_byte_array_ref_array ($keep, $items) {
    return pack('Q Q', 0, 0) unless defined $items && @$items;
    my $elements = join '', map { _pack_byte_array_ref($keep, $_) } @$items;
    my ($data_ptr) = Temporalio::Core::FFI::keep_buffer($keep, $elements);
    return pack('Q Q', $data_ptr, scalar @$items);
}

# build(\@keep, %options) — packs a complete TemporalCoreWorkerOptions and
# returns its opaque pointer. The pointer (and every pointer inside the
# struct) stays valid exactly as long as @$keep lives; callers hold @keep
# across the bridge call, the same lifetime discipline as
# Temporalio::Core::FFI::keep_buffer.
sub build ($keep, %options) {
    for my $field (sort keys %options) {
        _throw_argument("unknown WorkerOptions field '$field'")
            unless $KNOWN_FIELD{$field};
    }
    for my $field (@FIELDS) {
        _throw_argument("missing WorkerOptions field '$field'")
            unless exists $options{$field};
    }

    # Field offsets per the pinned header (x86-64 SysV), noted per line.
    my $buf = '';
    $buf .= _pack_byte_array_ref($keep, $options{namespace});             # 0
    $buf .= _pack_byte_array_ref($keep, $options{task_queue});            # 16
    $buf .= _pack_versioning_none($keep, $options{versioning_build_id}); # 32
    $buf .= _pack_byte_array_ref($keep, $options{identity_override});    # 80
    $buf .= pack('L x4', $options{max_cached_workflows});                # 96 (u32 + pad)
    $buf .= _pack_fixed_size_slot_supplier($options{$_})                 # 104 (4 x 48)
        for qw(workflow_slots activity_slots local_activity_slots nexus_task_slots);
    $buf .= pack('C4', map { $options{$_} ? 1 : 0 }                      # 296 (4 bools)
        qw(enable_workflows enable_local_activities enable_remote_activities enable_nexus));
    $buf .= "\0" x 4;                                                    # pad to 304
    $buf .= pack('Q', $options{sticky_queue_schedule_to_start_timeout_millis}); # 304
    $buf .= pack('Q', $options{max_heartbeat_throttle_interval_millis});        # 312
    $buf .= pack('Q', $options{default_heartbeat_throttle_interval_millis});    # 320
    $buf .= pack('d', $options{max_activities_per_second});              # 328 (f64)
    $buf .= pack('d', $options{max_task_queue_activities_per_second});   # 336 (f64)
    $buf .= pack('Q', $options{graceful_shutdown_period_millis});        # 344
    $buf .= _pack_simple_maximum_poller($keep, $options{workflow_task_poller_simple_maximum}); # 352
    $buf .= pack('f x4', $options{nonsticky_to_sticky_poll_ratio});      # 368 (f32 + pad)
    $buf .= _pack_simple_maximum_poller($keep, $options{activity_task_poller_simple_maximum}); # 376
    $buf .= _pack_simple_maximum_poller($keep, $options{nexus_task_poller_simple_maximum});    # 392
    $buf .= pack('C x7', $options{nondeterminism_as_workflow_fail} ? 1 : 0);    # 408 (bool + pad)
    $buf .= _pack_byte_array_ref_array($keep, $options{nondeterminism_as_workflow_fail_for_types}); # 416
    $buf .= _pack_byte_array_ref_array($keep, $options{plugins});         # 432
    $buf .= _pack_byte_array_ref_array($keep, $options{storage_drivers}); # 448
                                                                          # 464 total

    length($buf) == STRUCT_SIZE
        or die sprintf 'Temporalio::Core::FFI::WorkerOptions: packed %d bytes,'
                     . ' expected %d (layout drift?)', length($buf), STRUCT_SIZE;

    my ($ptr) = Temporalio::Core::FFI::keep_buffer($keep, $buf);
    return $ptr;
}

1;

__END__

=head1 NAME

Temporalio::Core::FFI::WorkerOptions - hand-packed TemporalCoreWorkerOptions builder

=head1 SYNOPSIS

    use Temporalio::Core::FFI::WorkerOptions ();

    my @keep;
    my $ptr = Temporalio::Core::FFI::WorkerOptions::build(\@keep,
        namespace           => 'default',
        task_queue          => 'demo',
        versioning_build_id => 'my-build',
        # ... every TemporalCoreWorkerOptions field; see @FIELDS
    );
    # $ptr is valid while @keep lives; pass it to temporal_core_worker_new.

=head1 DESCRIPTION

Packs the C<TemporalCoreWorkerOptions> struct tree byte-for-byte with
C<pack()>. The struct embeds tagged unions by value, which
L<FFI::Platypus::Record> cannot express, so the layout is transcribed from
the pinned C header and verified empirically by
F<t/unit/worker_options_marshal.t> against the bridge shim's
C<debug_worker_options> echo (spec section 11 risk spike 3).

v0.1 always passes versioning C<None{build_id}>, four C<FixedSize> slot
suppliers, and C<simple_maximum> poller behaviors per spec section 8.1.

=cut
