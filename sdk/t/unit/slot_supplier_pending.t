# ABOUTME: Custom slot-supplier reserve futures that are still pending must
# ABOUTME: defer permit issuance (spec R31; finding L19), not fabricate an
# ABOUTME: instant permit 1 that turns supplier backpressure into a grant.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FFI::Platypus::Memory ();
use Future ();
use Temporalio::Core::FFI ();
use Temporalio::Worker::SlotSupplierRegistry ();

# Finding L19 (spec R31): a custom slot supplier whose reserve_slot returned a
# still-pending Future got a fabricated instant permit 1 from _resolve_permit
# (Worker/SlotSupplierRegistry.pm:102-117,:141-148 pre-fix), so supplier
# backpressure (the whole point of returning a pending reserve future) became
# an unconditional grant, and the future's eventual resolved value was
# discarded. Required behavior: the reservation completion is DEFERRED to a
# continuation on the future and, on resolution, carries the future's value
# as the permit id. A permit id of 0 would panic core
# (temporal_core_complete_async_reserve: "permit_id cannot be 0"), so every
# issuing path must coerce to a positive integer.
#
# Adapted from probe verify-45/memsafe-infra/resolve_permit.pl (ephemeral
# scratch, no longer on disk); the pending-then-resolve drive is the probe's.
#
# The FFI mocks below follow t/unit/cow-tag-buffer.t: a mocked
# supplier_next_request parks exactly one REQ_RESERVE (tag 1) request, the
# slot_req_* accessors describe it, and supplier_complete_reserve records the
# (completion_ctx, permit_id) pairs the registry issues.

use constant {
    REQ_RESERVE  => 1,
    FAKE_REQ_PTR => 0x1234,
    COMPLETION   => 0xBEEF,
    SUPPLIER_ID  => 7,
};

T2->subtest('R31: the drain defers a pending reserve future' => sub {
    my $reserve_future = Future->new;    # still pending: backpressure
    my $impl = PendingSupplier->new(future => $reserve_future);
    Temporalio::Worker::SlotSupplierRegistry->_register_impl(
        SUPPLIER_ID, $impl);

    my @completions;
    my $served = 0;
    my $freed  = 0;
    no strict 'refs';
    no warnings 'redefine';
    local *{'Temporalio::Core::FFI::supplier_next_request'} = sub ($tag_ptr) {
        return 0 if $served++;
        FFI::Platypus::Memory::memset($tag_ptr, REQ_RESERVE, 1);
        return FAKE_REQ_PTR;
    };
    local *{'Temporalio::Core::FFI::slot_req_supplier_id'} =
        sub ($p) { SUPPLIER_ID };
    local *{'Temporalio::Core::FFI::slot_req_slot_type'}       = sub ($p) { 1 };
    local *{'Temporalio::Core::FFI::slot_req_is_sticky'}       = sub ($p) { 0 };
    local *{'Temporalio::Core::FFI::slot_req_task_queue'}      = sub ($p) { undef };
    local *{'Temporalio::Core::FFI::slot_req_worker_identity'} = sub ($p) { undef };
    local *{'Temporalio::Core::FFI::slot_req_worker_build_id'} = sub ($p) { undef };
    local *{'Temporalio::Core::FFI::byte_array_ref_to_scalar'} = sub ($r) { '' };
    local *{'Temporalio::Core::FFI::slot_req_completion_ctx'} =
        sub ($p) { COMPLETION };
    local *{'Temporalio::Core::FFI::supplier_free_request'} =
        sub ($p) { $freed++ };
    local *{'Temporalio::Core::FFI::supplier_complete_reserve'} =
        sub ($ctx, $permit_id) {
            push @completions, [$ctx, $permit_id];
            return 1;
        };

    Temporalio::Worker::SlotSupplierRegistry->_service_requests;

    T2->is($impl->reserve_calls, 1, 'reserve_slot ran on the drain');
    T2->is($freed, 1, 'the parked request box was freed');
    T2->is(\@completions, [],
        'no permit is issued while the reserve future is pending '
        . '(pre-fix: a fabricated instant permit 1)');

    # The supplier grants the slot later. The deferred continuation must
    # complete the reservation with the RESOLVED value. This is legal
    # after supplier_free_request because the completion ctx is core-owned
    # and was copied out of the parked request as a plain usize.
    $reserve_future->done(42);
    T2->is(\@completions, [[COMPLETION, 42]],
        'exactly one completion fires on resolution, carrying the resolved '
        . 'permit id (not the fabricated default 1)');

    Temporalio::Worker::SlotSupplierRegistry->_clear_active;
});

T2->subtest('R31: _resolve_permit pending vs resolved branches' => sub {
    my $reg = 'Temporalio::Worker::SlotSupplierRegistry';

    # PENDING: defer, then carry the resolved value.
    my @issued;
    my $pending = Future->new;
    $reg->_resolve_permit($pending, sub ($id) { push @issued, $id });
    T2->is(\@issued, [], 'pending future: nothing issued while pending');
    $pending->done(42);
    T2->is(\@issued, [42], 'resolution issues the resolved permit id once');

    # PENDING resolving to 0: coerced to the positive fallback, because a
    # permit id of 0 panics core.
    @issued = ();
    my $zero = Future->new;
    $reg->_resolve_permit($zero, sub ($id) { push @issued, $id });
    $zero->done(0);
    T2->is(\@issued, [1], 'a resolved 0 is coerced to the fallback permit 1');

    # RESOLVED: an already-done future yields its value immediately.
    @issued = ();
    $reg->_resolve_permit(Future->done(7), sub ($id) { push @issued, $id });
    T2->is(\@issued, [7], 'already-done future issues its value immediately');

    # IMMEDIATE: plain return values keep the v0.2 coercion contract.
    for my $case ([5, 5], [0, 1], ['abc', 1], [undef, 1]) {
        my ($in, $want) = @$case;
        @issued = ();
        $reg->_resolve_permit($in, sub ($id) { push @issued, $id });
        T2->is(\@issued, [$want],
            sprintf('immediate value %s issues permit %d',
                $in // 'undef', $want));
    }

    # ABNORMAL: failed and cancelled reserve futures warn and fall back to
    # the positive fallback permit so the reservation still completes
    # (never completing would wedge that reserve in core forever).
    @issued = ();
    my $warned = T2->warns(sub {
        $reg->_resolve_permit(Future->fail("boom\n"),
            sub ($id) { push @issued, $id });
    });
    T2->ok($warned, 'a failed reserve future warns');
    T2->is(\@issued, [1], 'a failed reserve future falls back to permit 1');

    @issued = ();
    my $cancelled = Future->new;
    $cancelled->cancel;
    $warned = T2->warns(sub {
        $reg->_resolve_permit($cancelled, sub ($id) { push @issued, $id });
    });
    T2->ok($warned, 'a cancelled reserve future warns');
    T2->is(\@issued, [1], 'a cancelled reserve future falls back to permit 1');
});

T2->done_testing;

# A custom-supplier impl whose reserve_slot exercises real backpressure by
# returning a still-pending Future the test resolves later.
package PendingSupplier {
    sub new ($class, %args) {
        return bless { future => $args{future}, reserve_calls => 0 }, $class;
    }
    sub reserve_calls ($self) { $self->{reserve_calls} }
    sub reserve_slot ($self, $ctx) {
        $self->{reserve_calls}++;
        return $self->{future};
    }
    sub try_reserve_slot  { return }
    sub mark_slot_used    { }
    sub release_slot      { }
}
