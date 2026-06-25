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
    VERSIONING_TAG_NONE                => 0,
    VERSIONING_TAG_DEPLOYMENT_BASED    => 1,
    VERSIONING_TAG_LEGACY_BUILD_ID     => 2,
    SLOT_SUPPLIER_TAG_FIXED_SIZE       => 0,
    SLOT_SUPPLIER_TAG_RESOURCE_BASED   => 1,
    SLOT_SUPPLIER_TAG_CUSTOM           => 2,
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
# versioning_build_id is the None{build_id} fallback. The DeploymentBased and
# LegacyBuildIdBased strategies arrive instead as versioning_deployment (a hash:
# deployment_name, build_id, use_worker_versioning, default_versioning_behavior)
# or versioning_legacy_build_id (a string); both are optional and only one may
# be set (Worker.pm enforces mutual exclusion). They are NOT in @FIELDS because
# they are optional alternatives, not required fields.
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
# Optional versioning alternatives to the None{build_id} default; accepted by
# build() but not required.
$KNOWN_FIELD{$_} = 1 for qw(versioning_deployment versioning_legacy_build_id);
# Optional per-pool slot-supplier specs (spec §29.2). When present they pack the
# pool's TemporalCoreSlotSupplier directly (FixedSize/ResourceBased/Custom);
# when absent the legacy *_slots => N FixedSize default is used. The four
# *_slots fields are therefore only required when no matching spec is given.
$KNOWN_FIELD{$_} = 1 for qw(
    workflow_slot_supplier_spec
    activity_slot_supplier_spec
    local_activity_slot_supplier_spec
    nexus_task_slot_supplier_spec
);
# Maps each slot-supplier-spec key to the *_slots field it replaces.
my %SLOT_SPEC_FOR = (
    workflow_slots       => 'workflow_slot_supplier_spec',
    activity_slots       => 'activity_slot_supplier_spec',
    local_activity_slots => 'local_activity_slot_supplier_spec',
    nexus_task_slots     => 'nexus_task_slot_supplier_spec',
);
# Optional per-pool poller-behavior specs (spec §29.3). When present they pack
# the pool's TemporalCorePollerBehavior directly (SimpleMaximum or Autoscaling);
# when absent the legacy *_poller_simple_maximum => N SimpleMaximum default is
# used. The three *_poller_simple_maximum fields are therefore only required
# when no matching behavior spec is given.
$KNOWN_FIELD{$_} = 1 for qw(
    workflow_task_poller_behavior_spec
    activity_task_poller_behavior_spec
    nexus_task_poller_behavior_spec
);
# Maps each poller-behavior-spec key to the *_poller_simple_maximum field it
# replaces.
my %POLLER_SPEC_FOR = (
    workflow_task_poller_simple_maximum => 'workflow_task_poller_behavior_spec',
    activity_task_poller_simple_maximum => 'activity_task_poller_behavior_spec',
    nexus_task_poller_simple_maximum    => 'nexus_task_poller_behavior_spec',
);

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

# TemporalCoreWorkerDeploymentOptions body (40 bytes, == the union size):
#   TemporalCoreWorkerDeploymentVersion version {
#       ByteArrayRef deployment_name;   // 16
#       ByteArrayRef build_id;          // 16
#   }                                   // 32
#   bool use_worker_versioning;         // 32 (+3 pad)
#   int32_t default_versioning_behavior;// 36
# (spec §29.1; header struct TemporalCoreWorkerDeploymentOptions.)
sub _pack_deployment_body ($keep, $deployment) {
    my $body = _pack_byte_array_ref($keep, $deployment->{deployment_name})
             . _pack_byte_array_ref($keep, $deployment->{build_id})
             . pack('C x3', $deployment->{use_worker_versioning} ? 1 : 0)
             . pack('l', $deployment->{default_versioning_behavior} // 0);
    return $body;
}

# TemporalCoreWorkerVersioningStrategy as DeploymentBased{deployment_options}.
sub _pack_versioning_deployment ($keep, $deployment) {
    return _pack_tagged_union(
        VERSIONING_TAG_DEPLOYMENT_BASED,
        _pack_deployment_body($keep, $deployment),
        VERSIONING_UNION_SIZE,
    );
}

# TemporalCoreWorkerVersioningStrategy as LegacyBuildIdBased{build_id}.
sub _pack_versioning_legacy ($keep, $build_id) {
    return _pack_tagged_union(
        VERSIONING_TAG_LEGACY_BUILD_ID,
        _pack_byte_array_ref($keep, $build_id),
        VERSIONING_UNION_SIZE,
    );
}

# pack_versioning_union(\@keep, \%spec) -> the 40-byte versioning union bytes.
# Exactly one of the spec keys selects the strategy:
#   { build_id        => $str }      -> None{build_id}        (tag 0)
#   { deployment      => \%hash }    -> DeploymentBased       (tag 1)
#   { legacy_build_id => $str }      -> LegacyBuildIdBased    (tag 2)
# The deployment hash needs deployment_name, build_id, use_worker_versioning,
# and default_versioning_behavior (a 0/1/2 proto enum value). Public so the
# marshalling test can inspect the packed tag/body directly.
sub pack_versioning_union ($keep, $spec) {
    if (defined $spec->{deployment}) {
        return _pack_versioning_deployment($keep, $spec->{deployment});
    }
    if (defined $spec->{legacy_build_id}) {
        return _pack_versioning_legacy($keep, $spec->{legacy_build_id});
    }
    return _pack_versioning_none($keep, $spec->{build_id});
}

# TemporalCoreSlotSupplier as FixedSize{num_slots}.
sub _pack_fixed_size_slot_supplier ($num_slots) {
    return _pack_tagged_union(
        SLOT_SUPPLIER_TAG_FIXED_SIZE,
        pack('Q', $num_slots),
        SLOT_SUPPLIER_UNION_SIZE,
    );
}

# TemporalCoreResourceBasedSlotSupplier body (40 bytes == the union size):
#   uintptr_t minimum_slots;            // 0
#   uintptr_t maximum_slots;            // 8
#   uint64_t  ramp_throttle_ms;         // 16
#   TemporalCoreResourceBasedTunerOptions tuner_options {
#       double target_memory_usage;     // 24
#       double target_cpu_usage;        // 32
#   }                                   // 40
# (header struct TemporalCoreResourceBasedSlotSupplier.)
sub _pack_resource_based_slot_supplier ($rb) {
    my $body = pack('Q Q Q',
        $rb->{minimum_slots}    // 0,
        $rb->{maximum_slots}    // 0,
        $rb->{ramp_throttle_ms} // 0,
    ) . pack('d d',
        $rb->{target_memory_usage} // 0,
        $rb->{target_cpu_usage}    // 0,
    );
    return _pack_tagged_union(
        SLOT_SUPPLIER_TAG_RESOURCE_BASED,
        $body,
        SLOT_SUPPLIER_UNION_SIZE,
    );
}

# TemporalCoreSlotSupplier as Custom{TemporalCoreCustomSlotSupplierCallbacksImpl}.
# The union body is a single pointer to the callbacks struct the shim allocated
# and @keep-pinned for the worker lifetime; 0/undef packs a NULL pointer (the
# worker binds the real pointer before passing the options to core).
sub _pack_custom_slot_supplier ($callbacks_ptr) {
    return _pack_tagged_union(
        SLOT_SUPPLIER_TAG_CUSTOM,
        pack('Q', $callbacks_ptr // 0),
        SLOT_SUPPLIER_UNION_SIZE,
    );
}

# pack_slot_supplier(\@keep, \%spec) -> the 48-byte TemporalCoreSlotSupplier
# union member (4-byte tag + 4 pad + 40-byte body). Exactly one spec key picks
# the variant:
#   { fixed_size     => $num_slots }   -> FixedSize     (tag 0)
#   { resource_based => \%hash }       -> ResourceBased (tag 1)
#   { custom         => $ptr }         -> Custom        (tag 2)
# The resource_based hash carries minimum_slots/maximum_slots/ramp_throttle_ms/
# target_memory_usage/target_cpu_usage. Public so the tuner unit test can
# inspect the packed tag/body directly. (\@keep is accepted for signature
# symmetry with pack_versioning_union; no variant here keeps extra buffers.)
sub pack_slot_supplier ($keep, $spec) {
    if (exists $spec->{resource_based}) {
        return _pack_resource_based_slot_supplier($spec->{resource_based});
    }
    if (exists $spec->{custom}) {
        return _pack_custom_slot_supplier($spec->{custom});
    }
    return _pack_fixed_size_slot_supplier($spec->{fixed_size});
}

# TemporalCorePollerBehavior is NOT a tagged union but a struct of two nullable
# pointers { const SimpleMaximum *simple_maximum; const Autoscaling *autoscaling; }
# (header:786-789). The active variant is the non-NULL pointer; the other is
# NULL. The outer struct is 16 bytes (two pointers) regardless of variant, so
# the WorkerOptions field offsets (352/376/392) never move.

# SimpleMaximum variant -> (simple_ptr, NULL). The sub-struct
# TemporalCorePollerBehaviorSimpleMaximum is one uintptr_t (header:776-778),
# kept in @keep so the pointer stays valid for the worker lifetime.
sub _pack_simple_maximum_poller ($keep, $maximum) {
    my ($struct_ptr) = Temporalio::Core::FFI::keep_buffer($keep, pack('Q', $maximum));
    return pack('Q Q', $struct_ptr, 0);
}

# Autoscaling variant -> (NULL, autoscaling_ptr). The sub-struct
# TemporalCorePollerBehaviorAutoscaling is three uintptr_t
# (minimum/maximum/initial, header:780-784), kept in @keep.
sub _pack_autoscaling_poller ($keep, $as) {
    my ($struct_ptr) = Temporalio::Core::FFI::keep_buffer($keep,
        pack('Q Q Q', $as->{minimum}, $as->{maximum}, $as->{initial}));
    return pack('Q Q', 0, $struct_ptr);
}

# pack_poller_behavior(\@keep, \%spec) -> the 16-byte TemporalCorePollerBehavior
# two-pointer struct. Exactly one spec key selects the variant:
#   { simple_maximum => $maximum }            -> SimpleMaximum  (simple_ptr, NULL)
#   { autoscaling    => { minimum, maximum, initial } } -> Autoscaling (NULL, ptr)
# Public so the poller-behavior unit test can inspect the packed pointers.
sub pack_poller_behavior ($keep, $spec) {
    if (defined $spec->{autoscaling}) {
        return _pack_autoscaling_poller($keep, $spec->{autoscaling});
    }
    return _pack_simple_maximum_poller($keep, $spec->{simple_maximum});
}

# TemporalCoreByteArrayRefArray { const TemporalCoreByteArrayRef *data;
# size_t size; } — element refs are packed contiguously into kept memory.
sub _pack_byte_array_ref_array ($keep, $items) {
    return pack('Q Q', 0, 0) unless defined $items && @$items;
    my $elements = join '', map { _pack_byte_array_ref($keep, $_) } @$items;
    my ($data_ptr) = Temporalio::Core::FFI::keep_buffer($keep, $elements);
    return pack('Q Q', $data_ptr, scalar @$items);
}

# _pack_poller_field(\@keep, \%options, $pool) -> the 16-byte poller-behavior
# struct for a pool ('workflow_task'/'activity_task'/'nexus_task'). Uses the
# pool's *_poller_behavior_spec when given, else synthesizes SimpleMaximum from
# the legacy *_poller_simple_maximum count (spec §29.3 override resolution is
# applied earlier in Worker.pm; this is the raw pack dispatch).
sub _pack_poller_field ($keep, $options, $pool) {
    my $spec_key = "${pool}_poller_behavior_spec";
    my $spec = defined $options->{$spec_key}
        ? $options->{$spec_key}
        : { simple_maximum => $options->{"${pool}_poller_simple_maximum"} };
    return pack_poller_behavior($keep, $spec);
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
    # versioning_build_id is the None{build_id} default; it is satisfied when
    # either a DeploymentBased or LegacyBuildIdBased alternative is supplied
    # instead (pack_versioning_union picks the right one).
    my $has_versioning_alt = defined $options{versioning_deployment}
        || defined $options{versioning_legacy_build_id};
    for my $field (@FIELDS) {
        next if $field eq 'versioning_build_id' && $has_versioning_alt;
        # A *_slots field is satisfied by its matching *_slot_supplier_spec
        # (spec §29.2): the spec packs that pool's supplier directly instead of
        # synthesizing a FixedSize from the count.
        if (my $spec_key = $SLOT_SPEC_FOR{$field}) {
            next if defined $options{$spec_key};
        }
        # A *_poller_simple_maximum field is satisfied by its matching
        # *_poller_behavior_spec (spec §29.3): the spec packs that pool's
        # PollerBehavior directly instead of synthesizing SimpleMaximum from N.
        if (my $spec_key = $POLLER_SPEC_FOR{$field}) {
            next if defined $options{$spec_key};
        }
        _throw_argument("missing WorkerOptions field '$field'")
            unless exists $options{$field};
    }

    # Field offsets per the pinned header (x86-64 SysV), noted per line.
    my $buf = '';
    $buf .= _pack_byte_array_ref($keep, $options{namespace});             # 0
    $buf .= _pack_byte_array_ref($keep, $options{task_queue});            # 16
    $buf .= pack_versioning_union($keep, {                               # 32
        build_id        => $options{versioning_build_id},
        deployment      => $options{versioning_deployment},
        legacy_build_id => $options{versioning_legacy_build_id},
    });
    $buf .= _pack_byte_array_ref($keep, $options{identity_override});    # 80
    $buf .= pack('L x4', $options{max_cached_workflows});                # 96 (u32 + pad)
    # The four slot suppliers (104, 4 x 48). Each pool packs from its explicit
    # *_slot_supplier_spec when given (FixedSize/ResourceBased/Custom), else
    # from the legacy *_slots => N FixedSize default (spec §29.2).
    for my $slots_field (qw(workflow_slots activity_slots local_activity_slots nexus_task_slots)) {
        my $spec_key = $SLOT_SPEC_FOR{$slots_field};
        my $spec = defined $options{$spec_key}
            ? $options{$spec_key}
            : { fixed_size => $options{$slots_field} };
        $buf .= pack_slot_supplier($keep, $spec);
    }
    $buf .= pack('C4', map { $options{$_} ? 1 : 0 }                      # 296 (4 bools)
        qw(enable_workflows enable_local_activities enable_remote_activities enable_nexus));
    $buf .= "\0" x 4;                                                    # pad to 304
    $buf .= pack('Q', $options{sticky_queue_schedule_to_start_timeout_millis}); # 304
    $buf .= pack('Q', $options{max_heartbeat_throttle_interval_millis});        # 312
    $buf .= pack('Q', $options{default_heartbeat_throttle_interval_millis});    # 320
    $buf .= pack('d', $options{max_activities_per_second});              # 328 (f64)
    $buf .= pack('d', $options{max_task_queue_activities_per_second});   # 336 (f64)
    $buf .= pack('Q', $options{graceful_shutdown_period_millis});        # 344
    # The three poller behaviors (spec §29.3). Each pool packs from its explicit
    # *_poller_behavior_spec when given (SimpleMaximum/Autoscaling), else from
    # the legacy *_poller_simple_maximum => N SimpleMaximum default. The outer
    # struct is 16 bytes either way, so offsets 352/376/392 are fixed.
    $buf .= _pack_poller_field($keep, \%options, 'workflow_task'); # 352
    $buf .= pack('f x4', $options{nonsticky_to_sticky_poll_ratio});      # 368 (f32 + pad)
    $buf .= _pack_poller_field($keep, \%options, 'activity_task'); # 376
    $buf .= _pack_poller_field($keep, \%options, 'nexus_task');    # 392
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

=encoding utf8

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

=head1 METHODS

=head2 build

Builds the by-value C<TemporalCoreWorkerOptions> record (with hand-packed tagged unions) from the SDK-level worker options.

=head2 pack_versioning_union

Packs the 48-byte C<TemporalCoreWorkerVersioningStrategy> union member from a
strategy spec (spec §29.1). Public so the marshalling test can inspect the
packed tag/body.

=head2 pack_slot_supplier

Packs the 48-byte C<TemporalCoreSlotSupplier> union member from a supplier spec
(C<fixed_size>/C<resource_based>/C<custom>; spec §29.2). Public so the tuner
test can inspect the packed tag/body.

=head2 pack_poller_behavior

Packs the 16-byte C<TemporalCorePollerBehavior> two-pointer struct from a poller
spec (C<simple_maximum> or C<autoscaling>; spec §29.3). The struct is two
nullable pointers, not a tagged union: SimpleMaximum is C<(ptr, NULL)>,
Autoscaling is C<(NULL, ptr)>. Public so the poller-behavior unit test can
inspect the packed pointers.

=cut
