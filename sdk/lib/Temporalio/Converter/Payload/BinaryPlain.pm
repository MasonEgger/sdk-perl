# ABOUTME: Payload converter for raw bytes — the Temporal-spec binary/plain
# ABOUTME: encoding for byte strings and RawBytes-hinted values (spec section 5.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
no warnings 'experimental::builtin';

use Scalar::Util ();
use Temporalio::Converter::Payload;
use Temporalio::Payload ();
use Temporalio::Payload::RawBytes ();

class Temporalio::Converter::Payload::BinaryPlain
    :isa(Temporalio::Converter::Payload)
{
    method encoding { 'binary/plain' }

    method to_payload ($value) {
        my $bytes;
        if (Scalar::Util::blessed($value)
            && $value->isa('Temporalio::Payload::RawBytes'))
        {
            $bytes = $value->bytes;
        }
        elsif (defined $value
            && !ref $value
            && builtin::created_as_string($value)
            && !utf8::is_utf8($value))
        {
            # Spec section 5.2: a string without the UTF-8 flag IS raw bytes.
            # Numbers are not strings and fall through to the Json catch-all.
            $bytes = $value;
        }
        else {
            return undef;
        }
        return Temporalio::Payload->new({
            metadata => { encoding => $self->encoding },
            data     => $bytes,
        });
    }

    method from_payload ($payload, $type_hint = undef) {
        return $payload->data // '';
    }
}

1;

__END__

=head1 NAME

Temporalio::Converter::Payload::BinaryPlain - the binary/plain encoding

=head1 DESCRIPTION

Handles raw bytes: values wrapped in L<Temporalio::Payload::RawBytes>, and
plain Perl strings without the internal UTF-8 flag (per spec section 5.2, an
unflagged string is bytes; numeric scalars are not strings and fall through
to the C<json/plain> catch-all). C<to_payload> stores the bytes verbatim
under encoding C<binary/plain>; C<from_payload> returns the data bytes as a
plain scalar (not re-wrapped). C<encoding> returns C<binary/plain>. See
L<Temporalio::Converter::Payload> for the converter contract.

=cut
