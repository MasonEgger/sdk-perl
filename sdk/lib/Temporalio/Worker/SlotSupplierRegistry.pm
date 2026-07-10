# ABOUTME: Process-global registry of active custom slot-supplier impls (spec
# ABOUTME: §29.2), mirroring Runtime::MetricMeter. The shim routes every
# ABOUTME: custom-supplier callback to one registry; the drain looks up the
# ABOUTME: impl by the shim-allocated supplier id and runs its method on the
# ABOUTME: main thread, completing async reservations via the shim.
use v5.38;
use warnings;

package Temporalio::Worker::SlotSupplierRegistry;

our $VERSION = '0.2.0';

use Temporalio::Core::FFI ();
use Scalar::Util ();

# The slot-kind type integers core passes in SlotReserveCtx.slot_type / the
# SlotInfo tag (header TemporalCoreSlotKindType / SlotInfo_Tag).
use constant {
    SLOT_KIND_WORKFLOW        => 0,
    SLOT_KIND_ACTIVITY        => 1,
    SLOT_KIND_LOCAL_ACTIVITY  => 2,
    SLOT_KIND_NEXUS           => 3,
};
my %SLOT_KIND_NAME = (
    0 => 'workflow',
    1 => 'activity',
    2 => 'local-activity',
    3 => 'nexus',
);

# Request tags (must match the shim's TEMPORALIO_PERL_BRIDGE_SLOT_REQ_*).
use constant {
    REQ_RESERVE     => 1,
    REQ_TRY_RESERVE => 2,
    REQ_MARK_USED   => 3,
    REQ_RELEASE     => 4,
    REQ_FREE        => 5,
};

# active() true while a runtime owns the registry. The shim enforces "one per
# process" via the register compare-and-set; this mirror lets the drain decide
# whether to service supplier requests at all (and the Runtime refuse a second).
my $ACTIVE = 0;
# supplier id (shim-allocated) => the Perl impl object.
my %IMPL;

sub active     ($class) { $ACTIVE }
sub _set_active ($class) { $ACTIVE = 1; return }
sub _clear_active ($class) {
    $ACTIVE = 0;
    %IMPL = ();
    return;
}

# Bind a supplier id (returned by the shim's supplier_new) to its Perl impl.
sub _register_impl ($class, $id, $impl) {
    $IMPL{$id} = $impl;
    return;
}

# Run every parked supplier request on the main-thread drain. The shim parked
# each off a core thread; supplier_next_request pops the next (with its tag),
# this runs the matching impl method, then supplier_free_request frees it.
# A reserve request completes the async reservation via the shim once the impl
# returns a permit. An impl method that dies is caught + warned (it must never
# unwind across the C ABI the drain runs under).
sub _service_requests ($class) {
    # The 1-byte tag slot the shim writes into must be a private non-COW
    # buffer (finding L4 / spec R28); see Core::FFI::private_write_buffer.
    my $tag_slot;
    my $tag_ptr = Temporalio::Core::FFI::private_write_buffer($tag_slot, 1);
    while (1) {
        my $request_ptr =
            Temporalio::Core::FFI::supplier_next_request($tag_ptr);
        last unless defined $request_ptr && $request_ptr;
        my $tag = unpack 'C', $tag_slot;
        eval { $class->_dispatch($tag, $request_ptr); 1 } or do {
            my $err = $@;
            warn "Temporalio::Worker::SlotSupplierRegistry: supplier method"
                . " threw, ignoring: $err";
        };
        Temporalio::Core::FFI::supplier_free_request($request_ptr);
    }
    return;
}

# Dispatch one parked request to the bound impl.
sub _dispatch ($class, $tag, $request_ptr) {
    my $id   = Temporalio::Core::FFI::slot_req_supplier_id($request_ptr);
    my $impl = $IMPL{$id};

    if ($tag == REQ_FREE) {
        # Core dropped the supplier; forget the impl (a release_resources hook
        # is optional — call it if the impl provides one).
        if (defined $impl && $impl->can('on_free')) {
            $impl->on_free;
        }
        delete $IMPL{$id};
        return;
    }
    return unless defined $impl;

    if ($tag == REQ_RESERVE) {
        my $ctx = $class->_reserve_ctx($request_ptr);
        # reserve_slot is async per the contract; an immediate (non-Future)
        # return value is a resolved reservation, completed right here on the
        # drain. A Future return is honored as real backpressure: a
        # still-pending future DEFERS the completion until it resolves
        # (finding L19 / spec R31) instead of fabricating an instant permit.
        my $permit = $impl->reserve_slot($ctx);
        # Read the completion ctx BEFORE the drain frees the request box: the
        # ctx is core-owned and was copied into the parked request as a plain
        # usize, so it stays valid for a deferred completion fired after
        # supplier_free_request. See the shim reserve-timing note above
        # _resolve_permit.
        my $completion =
            Temporalio::Core::FFI::slot_req_completion_ctx($request_ptr);
        return unless defined $completion && $completion;
        $class->_resolve_permit($permit, sub ($permit_id) {
            # A false return means core cancelled the reserve before this
            # completion; the permit is simply dropped (that path's ctx leak
            # is the shim's pre-existing cancel_reserve no-op behavior).
            Temporalio::Core::FFI::supplier_complete_reserve(
                $completion, $permit_id);
        });
        return;
    }
    if ($tag == REQ_TRY_RESERVE) {
        # The shim already declined (returned 0) on the core thread; this run is
        # purely for observation — call try_reserve_slot so the impl sees it.
        my $ctx = $class->_reserve_ctx($request_ptr);
        $impl->try_reserve_slot($ctx);
        return;
    }
    if ($tag == REQ_MARK_USED) {
        $impl->mark_slot_used($class->_used_ctx($request_ptr));
        return;
    }
    if ($tag == REQ_RELEASE) {
        $impl->release_slot($class->_release_ctx($request_ptr));
        return;
    }
    return;
}

# Resolve a reserve_slot return value into a permit id and hand it to $issue
# exactly once (finding L19 / spec R31). Pre-fix, a still-pending Future was
# collapsed to a fabricated instant permit 1, turning supplier backpressure
# into an unconditional grant and discarding the eventual resolved value.
#
# Shim reserve-timing note (checked for R31; the shim is UNCHANGED): the
# shim's supplier_cancel_reserve is a no-op whose comment assumed the drain
# resolved every reserve immediately. Deferred completion stays safe because
#   - the completion ctx is core-owned (an Arc leaked to lang) and is copied
#     into the parked SlotRequest as a usize, so it remains valid after
#     supplier_free_request frees the request box;
#   - temporal_core_complete_async_reserve on a reservation core already
#     cancelled returns false WITHOUT freeing (no double-free); the ctx leak
#     on that path is the shim's pre-existing cancel_reserve behavior, not
#     new with the deferral;
#   - a permit id of 0 panics core ("permit_id cannot be 0"), so every
#     issuing path coerces the value through _permit_id (always >= 1).
sub _resolve_permit ($class, $permit, $issue) {
    if (Scalar::Util::blessed($permit) && $permit->can('is_ready')) {
        # PENDING branch: the supplier is exerting backpressure. Defer the
        # completion to a continuation on the future; issue nothing now.
        if (!$permit->is_ready && $permit->can('on_ready')) {
            $permit->on_ready(sub ($f) {
                # The continuation runs in the resolver's context (user code
                # or the loop), outside the drain's per-entry eval; it must
                # never unwind into the resolver.
                eval { $issue->($class->_future_permit_id($f)); 1 } or warn
                    "Temporalio::Worker::SlotSupplierRegistry: deferred"
                    . " reserve completion threw, ignoring: $@";
            });
            return;
        }
        # RESOLVED branch: an already-settled future yields its value now
        # (failed/cancelled shapes fall back inside _future_permit_id).
        $issue->($class->_future_permit_id($permit));
        return;
    }
    # IMMEDIATE branch: a plain return value is a resolved reservation.
    $issue->($class->_permit_id($permit));
    return;
}

# Extract a permit id from a settled reserve future. A failed or cancelled
# future (or a duck-typed pending one we could not defer on) warns and falls
# back to permit 1: reservation cannot error toward core, and never
# completing would wedge that reserve in core forever.
sub _future_permit_id ($class, $f) {
    my $value = eval { my ($v) = $f->get; $v };
    if (my $err = $@) {
        warn "Temporalio::Worker::SlotSupplierRegistry: reserve future did"
            . " not yield a value, issuing fallback permit 1: $err";
        return 1;
    }
    return $class->_permit_id($value);
}

# A permit id must be a POSITIVE integer the shim hands back to core for
# mark_used/release; temporal_core_complete_async_reserve panics on 0.
# Anything non-conforming is coerced to the small positive fallback 1 so the
# reservation still completes.
sub _permit_id ($class, $value) {
    return 1 unless defined $value && !ref $value;
    return $value if $value =~ /\A[0-9]+\z/ && $value > 0;
    return 1;
}

# Build the reserve context hash from the parked request.
sub _reserve_ctx ($class, $request_ptr) {
    my $type = Temporalio::Core::FFI::slot_req_slot_type($request_ptr);
    return {
        slot_type       => $SLOT_KIND_NAME{$type} // 'workflow',
        task_queue      => _ref_str(
            Temporalio::Core::FFI::slot_req_task_queue($request_ptr)),
        worker_identity => _ref_str(
            Temporalio::Core::FFI::slot_req_worker_identity($request_ptr)),
        worker_build_id => _ref_str(
            Temporalio::Core::FFI::slot_req_worker_build_id($request_ptr)),
        is_sticky       =>
            Temporalio::Core::FFI::slot_req_is_sticky($request_ptr) ? 1 : 0,
    };
}

sub _used_ctx ($class, $request_ptr) {
    my $type = Temporalio::Core::FFI::slot_req_slot_info_type($request_ptr);
    return {
        slot_info => { slot_type => $SLOT_KIND_NAME{$type} },
        permit    => Temporalio::Core::FFI::slot_req_permit($request_ptr),
    };
}

sub _release_ctx ($class, $request_ptr) {
    my $type = Temporalio::Core::FFI::slot_req_slot_info_type($request_ptr);
    # A slot_info_type of -1 means the slot was never used (NULL slot_info).
    return {
        slot_info => $type < 0 ? undef : { slot_type => $SLOT_KIND_NAME{$type} },
        permit    => Temporalio::Core::FFI::slot_req_permit($request_ptr),
    };
}

# Read a TemporalCoreByteArrayRef-by-value (the slot_req_* string accessors)
# into a Perl string; NULL/empty yields ''.
sub _ref_str ($ref) {
    return Temporalio::Core::FFI::byte_array_ref_to_scalar($ref);
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::SlotSupplierRegistry - main-thread runner for custom slot-supplier callbacks

=head1 DESCRIPTION

Holds the active custom slot-supplier impls (spec §29.2) keyed by the shim's
supplier id. Core invokes the supplier callbacks on its own threads; the shim
parks each request, and L<Temporalio::Core::Callback>'s drain calls
C<_service_requests> on the main thread to run the impl's C<reserve_slot> /
C<try_reserve_slot> / C<mark_slot_used> / C<release_slot> methods and complete
async reservations.

=head1 METHODS

=head2 active

True while a runtime owns the process-global custom slot-supplier registry. The
drain checks this before servicing parked supplier requests.

=cut
