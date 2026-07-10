# ABOUTME: Asserts the 1-byte tag slots handed to the shim for writing are
# ABOUTME: private non-COW buffers (spec R28; finding L4).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FFI::Platypus::Buffer ();
use FFI::Platypus::Memory ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Worker::SlotSupplierRegistry ();

# Finding L4 (spec R28), committed adaptation of the step-45 probe
# verify-45/memsafe-infra/cow_tag.pl. Code trace:
#
# - `my $tag_slot = "\0"` makes the slot a copy-on-write alias of the "\0"
#   op-tree constant at that source line. scalar_to_buffer exposes the
#   SHARED PV, so the shim's tag write (ext/temporalio-perl-bridge/src/
#   lib.rs, meter_next_request's `*out_tag = req.tag` and its supplier
#   twin) silently corrupts the constant and every COW sibling: each later
#   execution of the same line yields a slot born with the stale tag byte.
# - Affected sites (finding line refs): Core/Callback.pm:362-363
#   (_service_meter_requests) and Worker/SlotSupplierRegistry.pm:69-70
#   (_service_requests).
#
# Audit note: every scalar_to_buffer call site in sdk/lib, checked for the
# same hazard:
#
# - Core/Callback.pm _service_meter_requests tag slot: shim-written, WAS
#   COW (the defect); now a private buffer via
#   Temporalio::Core::FFI::private_write_buffer.
# - Worker/SlotSupplierRegistry.pm _service_requests tag slot: same
#   defect, same fix.
# - Core/Callback.pm drain entry buffer and _drain_meter_records record
#   buffer: shim-written, but built with `"\0" x ($stride * $cap)` on
#   runtime operands, so the repeat writes straight into the lexical's
#   private PV (no IsCOW; verified with Devel::Peek) and no fix is needed.
# - Runtime/LoggingConfig.pm filter string and Core/FFI.pm keep_buffer:
#   the shim only READS through these pointers; COW is harmless without a
#   foreign write.
#
# The mocks below replace the shim's next-request pop with a sub that
# performs exactly the shim's one-byte write through the raw tag pointer,
# then returns 0 (null): the drain loop exits before dispatch, and the
# write is the event under test.

my $TAG_BYTE = 0x2A;

# Drive one service pass with a mocked next-request that writes $TAG_BYTE
# through the tag pointer, then a second pass whose mock peeks the fresh
# slot's initial byte. Returns that byte. Pre-fix the write poisons the
# "\0" constant inside the service sub, so the second pass sees $TAG_BYTE.
sub drive_and_peek ($glob_name, $service) {
    my $peeked;
    no strict 'refs';
    no warnings 'redefine';
    local *{"Temporalio::Core::FFI::$glob_name"} = sub ($tag_ptr) {
        FFI::Platypus::Memory::memset($tag_ptr, $TAG_BYTE, 1);
        return 0;
    };
    $service->();
    local *{"Temporalio::Core::FFI::$glob_name"} = sub ($tag_ptr) {
        $peeked = FFI::Platypus::Buffer::buffer_to_scalar($tag_ptr, 1);
        return 0;
    };
    $service->();
    return $peeked;
}

T2->subtest('R28: supplier tag slot survives a shim write privately' => sub {
    my $independent = "\0";    # created before the foreign write

    my $fresh_byte = drive_and_peek(
        supplier_next_request =>
            sub { Temporalio::Worker::SlotSupplierRegistry->_service_requests });

    T2->is($independent, "\0",
        'independently created "\0" scalar is untouched by the shim write');
    T2->is(sprintf('%02X', ord $fresh_byte), '00',
        'the next service pass starts from a clean "\0" tag slot '
        . '(the "\0" constant was not poisoned)');
});

T2->subtest('R28: meter tag slot survives a shim write privately' => sub {
    my $independent = "\0";

    my $fresh_byte = drive_and_peek(
        meter_next_request =>
            sub { Temporalio::Core::Callback::_service_meter_requests() });

    T2->is($independent, "\0",
        'independently created "\0" scalar is untouched by the shim write');
    T2->is(sprintf('%02X', ord $fresh_byte), '00',
        'the next service pass starts from a clean "\0" tag slot '
        . '(the "\0" constant was not poisoned)');
});

T2->subtest('R28: private_write_buffer yields a NUL-filled private buffer' => sub {
    my $slot;
    my $ptr = Temporalio::Core::FFI::private_write_buffer($slot, 4);
    T2->is(length $slot, 4, 'slot has the requested length');
    T2->is($slot, "\0" x 4, 'slot content is all NUL bytes');

    my $sibling = $slot;    # plain Perl copy taken before the foreign write
    FFI::Platypus::Memory::memset($ptr, $TAG_BYTE, 4);
    T2->is($slot, chr($TAG_BYTE) x 4, 'the foreign write lands in the slot');
    T2->is($sibling, "\0" x 4, 'a pre-write copy of the slot is unaffected');
});

T2->done_testing;
