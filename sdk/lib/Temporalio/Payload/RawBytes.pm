# ABOUTME: Hint wrapper marking a Perl scalar as raw bytes so the payload
# ABOUTME: converter selects the binary/plain encoding unambiguously.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

class Temporalio::Payload::RawBytes {
    field $bytes :param;

    ADJUST {
        if (!defined $bytes || ref $bytes) {
            Temporalio::Exception::Argument->throw(
                message => 'RawBytes requires a defined, non-reference bytes scalar',
            );
        }

        # Byte purity at the payload boundary (spec R6, finding L21). A
        # UTF8-flagged scalar carries character semantics: downstream the
        # pure-Perl proto encoder's `bytes` arm frames length() CHARACTERS
        # while the FFI boundary writes the UTF-8 PV BYTES (probe: 34
        # framed vs 36 written), silently corrupting the frame. Downgrade
        # is byte-identical when every codepoint fits a byte; a genuinely
        # wide scalar has no byte representation, and guessing an encoding
        # for "raw bytes" would be wrong, so reject it with the typed
        # error. Invariant: the stored buffer is always pure bytes, so
        # framed length == bytes written everywhere downstream.
        if (utf8::is_utf8($bytes) && !utf8::downgrade($bytes, 1)) {
            Temporalio::Exception::Argument->throw(
                message => 'RawBytes requires a byte string: the value contains '
                    . 'wide characters (codepoints above 0xFF) with no byte '
                    . 'representation; encode it first (e.g. utf8::encode)',
            );
        }
    }

    method bytes { $bytes }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Payload::RawBytes - mark a scalar as raw bytes for conversion

=head1 SYNOPSIS

    use Temporalio::Payload::RawBytes;

    my $hint = Temporalio::Payload::RawBytes->new(bytes => $blob);
    my $payload = $converter->to_payload($hint);   # binary/plain

=head1 DESCRIPTION

Wraps a Perl scalar to tell L<Temporalio::Converter::Payload::BinaryPlain>
unambiguously that the value is raw bytes and must use the C<binary/plain>
encoding, useful when the scalar would otherwise be claimed by another
converter. C<bytes> returns the wrapped scalar.

The constructor enforces byte purity (spec R6): a UTF8-flagged scalar
whose codepoints all fit in a byte is downgraded to its byte-identical
octet form; a scalar containing wide characters (codepoints above 0xFF)
has no byte representation and raises
L<Temporalio::Exception::Argument>. Encode such values to bytes first,
for example with C<utf8::encode>. The stored buffer is therefore always
pure bytes, so the proto frame length always equals the bytes written at
the FFI boundary.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Payload::RawBytes->new(
        bytes => ...,
    );

Constructs a Temporalio::Payload::RawBytes. Named parameters:

=over 4

=item C<bytes>

(required)

=back

=head1 METHODS

=head2 bytes

Accessor returning the C<bytes> value.

=cut
