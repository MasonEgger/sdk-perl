# ABOUTME: Asserts byte purity at the RawBytes payload boundary and that the
# ABOUTME: FFI framing length always equals the bytes written (spec R6; L21).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FFI::Platypus::Buffer ();
use Temporalio::Core::FFI ();
use Temporalio::Payload;
use Temporalio::Payload::RawBytes;

# Finding L21 (spec R6), committed adaptation of the step-45 probe.
# Code trace:
#
# - Payload/RawBytes.pm:13-18 accepted any non-reference scalar, including
#   a UTF8-flagged wide-character string. Perl's dual string representation
#   then leaks into the wire path: the pure-Perl proto encoder's `bytes`
#   arm does a NON-FATAL utf8::downgrade (proto3-perl Codec.pm:119), so a
#   wide value survives downgrade-failure silently -- the length varint
#   counts CHARACTERS while the concatenated frame carries the UTF-8
#   ENCODING of those characters (probe measured 34 framed vs 36 written).
# - Core/FFI.pm:522-527 (keep_buffer) then hands scalar_to_buffer the wide
#   frame: the pointer exposes the UTF-8 PV, so the byte count the bridge
#   receives disagrees with every character-semantics length() computed
#   upstream. Corrupted frames cross the wire silently.
#
# Contract under test (spec R6 required behavior): the byte length used
# for framing equals the bytes actually written, always. RawBytes enforces
# byte purity at construction: a UTF8-flagged latin-1-range scalar is
# downgraded (byte-identical); a genuinely wide scalar (codepoint > 0xFF)
# raises the documented Temporalio::Exception::Argument. keep_buffer
# normalizes to a pure byte buffer before scalar_to_buffer.

# Round-trip a scalar through keep_buffer and read back the exact byte
# image the bridge would see: returns (framed size, bytes written).
sub keep_buffer_image ($scalar) {
    my @keep;
    my ($ptr, $size) = Temporalio::Core::FFI::keep_buffer(\@keep, $scalar);
    my $written = FFI::Platypus::Buffer::buffer_to_scalar($ptr, $size);
    return ($size, $written);
}

T2->subtest('R6: wide-character RawBytes never yields a mismatched frame' => sub {
    my $wide = "sn\x{2603}w";    # 4 characters, 6 UTF-8 bytes: the 34-vs-36 shape

    my $rb = eval { Temporalio::Payload::RawBytes->new(bytes => $wide) };
    if (!defined $rb) {
        # The documented outcome: reject with the typed error, no guessing
        # at an encoding for "raw bytes" that have no byte representation.
        T2->isa_ok(
            $@, ['Temporalio::Exception::Argument'],
            'wide scalar rejected with the documented typed error');
        T2->like(
            $@->message, qr/wide|byte/i,
            'diagnostic names the wide-character/byte-purity hazard');
    }
    else {
        # If construction accepts the value it must have normalized it to
        # pure bytes, and the emitted proto frame must be self-consistent:
        # frame length == bytes written, data intact after decode. Pre-fix
        # this branch runs and fails: the stored scalar stays UTF8-flagged
        # and the frame's data varint counts characters, not bytes.
        T2->ok(!utf8::is_utf8($rb->bytes),
            'accepted wide input was normalized to pure bytes');

        my $payload = Temporalio::Payload->new({
            metadata => { encoding => 'binary/plain' },
            data     => $rb->bytes,
        });
        my $frame = $payload->encode;
        my ($size, $written) = keep_buffer_image($frame);
        T2->is($size, do { use bytes; length $frame },
            'framed length equals the bytes written to the FFI buffer');

        my $decoded = eval { Temporalio::Payload->decode($written) };
        T2->ok(defined $decoded,
            'the byte image handed to the bridge decodes cleanly')
            or T2->diag("decode error: $@");
        T2->ok($decoded && $decoded->data eq $rb->bytes,
            'payload data survives the frame byte-identically');
    }
});

T2->subtest('R6: latin-1-range UTF8-flagged scalar round-trips byte-identically' => sub {
    # The ambiguous case: UTF8-flagged but every codepoint <= 0xFF, so a
    # byte-identical downgrade exists and MUST be taken (spec R6 acceptance
    # criterion 2). Pre-fix the flag survives construction and keep_buffer
    # writes the 5-byte UTF-8 PV (0xE9 -> 0xC3 0xA9) while framing math
    # upstream counted 4 characters -- the mismatch shape from the probe.
    my $ambiguous = "caf\xE9";
    utf8::upgrade($ambiguous);

    my $rb = Temporalio::Payload::RawBytes->new(bytes => $ambiguous);
    T2->ok(!utf8::is_utf8($rb->bytes),
        'stored bytes are downgraded to pure octets');
    T2->is($rb->bytes, "caf\xE9", 'stored octet sequence is unchanged');

    my ($size, $written) = keep_buffer_image($rb->bytes);
    T2->is($size, 4,
        'framing length is the octet count (4), not the UTF-8 PV length (5)');
    T2->is($written, "caf\xE9", 'the bytes written are the original octets');
});

T2->subtest('R6: keep_buffer frames exactly the bytes it writes' => sub {
    # Guard assertions for the framed-length == bytes-written invariant at
    # the keep_buffer boundary itself, per the spec R6 test notes (every
    # scalar_to_buffer site in Core/FFI.pm checked; R28 owns the COW
    # write-slot variant in private_write_buffer).
    my $ascii = 'plain ascii payload';
    my ($asize, $awritten) = keep_buffer_image($ascii);
    T2->is($asize, length $ascii, 'ASCII: framed length == byte length');
    T2->is($awritten, $ascii, 'ASCII: bytes written match the payload');

    my $nul = "\x00abc\x00def\x00";
    my ($nsize, $nwritten) = keep_buffer_image($nul);
    T2->is($nsize, 9, 'embedded NULs: framed length counts every byte');
    T2->is($nwritten, $nul, 'embedded NULs: bytes written match the payload');

    # An upgraded latin-1 scalar reaching keep_buffer directly (not via
    # RawBytes) is normalized to its byte-identical downgraded form.
    my $upgraded = "tag\xFFbyte";
    utf8::upgrade($upgraded);
    my ($usize, $uwritten) = keep_buffer_image($upgraded);
    T2->is($usize, 8,
        'upgraded latin-1: framed length is the octet count (8), not the PV length (9)');
    T2->is($uwritten, "tag\xFFbyte",
        'upgraded latin-1: bytes written are the downgraded octets');

    # A genuinely wide string has no byte form; keep_buffer encodes it to
    # UTF-8 deterministically so the frame and the written bytes agree.
    my $wide    = "sn\x{2603}w";
    my $encoded = do { my $c = $wide; utf8::encode($c); $c };
    my ($wsize, $wwritten) = keep_buffer_image($wide);
    T2->is($wsize, do { use bytes; length $encoded },
        'wide: framed length is the UTF-8 byte count');
    T2->is($wwritten, $encoded, 'wide: bytes written are the UTF-8 encoding');
});

T2->done_testing;
