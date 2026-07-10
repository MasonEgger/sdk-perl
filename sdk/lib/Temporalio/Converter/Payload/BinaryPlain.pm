# ABOUTME: Payload converter for raw bytes — the Temporal-spec binary/plain
# ABOUTME: encoding, claimed only by RawBytes-wrapped values (spec section 5.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Converter::Payload;
use Temporalio::Payload ();
use Temporalio::Payload::RawBytes ();

class Temporalio::Converter::Payload::BinaryPlain
    :isa(Temporalio::Converter::Payload)
{
    method encoding { 'binary/plain' }

    method to_payload ($value) {
        # binary/plain is claimed ONLY by an explicit RawBytes wrapper. Perl has
        # no distinct byte-string type, so a bare scalar is treated as text and
        # falls through to the json/plain catch-all — matching sdk-python (only
        # `bytes` is binary) and sdk-ruby (only ASCII_8BIT strings). Auto-routing
        # plain strings here would emit binary/plain that other SDKs decode as
        # bytes, not a string, and that tooling shows as base64 (spec section 5.2).
        return undef
            unless Scalar::Util::blessed($value)
            && $value->isa('Temporalio::Payload::RawBytes');

        return Temporalio::Payload->new({
            metadata => { encoding => $self->encoding },
            data     => $value->bytes,
        });
    }

    method from_payload ($payload, $type_hint = undef) {
        return $payload->data // '';
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Converter::Payload::BinaryPlain - the binary/plain encoding

=head1 DESCRIPTION

Handles raw bytes: C<to_payload> claims only values wrapped in
L<Temporalio::Payload::RawBytes> (spec R59; the isa-check in the claiming
code is the whole condition). Bare Perl scalars, with or without the
internal UTF-8 flag, are never claimed here and fall through to the
C<json/plain> catch-all, matching sdk-python (only C<bytes> is binary)
and sdk-ruby (only ASCII_8BIT strings). C<to_payload> stores the bytes
verbatim under encoding C<binary/plain>; C<from_payload> returns the data
bytes as a plain scalar (not re-wrapped), the empty string when the data
is empty or unset (spec R58, Python parity with C<b''>). C<encoding>
returns C<binary/plain>. See L<Temporalio::Converter::Payload> for the
converter contract.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Converter::Payload::BinaryPlain.

=cut
