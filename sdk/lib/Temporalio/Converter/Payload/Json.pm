# ABOUTME: Catch-all payload converter via canonical JSON::PP — the
# ABOUTME: Temporal-spec json/plain encoding (spec section 5.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use JSON::PP ();
use Scalar::Util ();
use Temporalio::Converter::Payload;
use Temporalio::Exception::DataConverter ();
use Temporalio::Payload ();

class Temporalio::Converter::Payload::Json
    :isa(Temporalio::Converter::Payload)
{
    field $json;

    ADJUST {
        # Spec section 5.2: canonical => 1, allow_blessed => 0. allow_nonref
        # lets bare scalars round-trip (matching the reference SDKs); utf8
        # keeps payload data in bytes.
        $json = JSON::PP->new->canonical(1)->allow_blessed(0)
            ->allow_nonref(1)->utf8(1);
    }

    method encoding { 'json/plain' }

    method to_payload ($value) {
        return undef unless defined $value;                  # binary/null's job
        return undef if Scalar::Util::blessed($value);       # composite raises
        if (my $ref = ref $value) {
            # Hashrefs, arrayrefs, and JSON::PP boolean scalar refs only.
            return undef
                unless $ref eq 'HASH' || $ref eq 'ARRAY' || $ref eq 'SCALAR';
        }

        my $data = eval { $json->encode($value) };
        unless (defined $data) {
            Temporalio::Exception::DataConverter->throw(
                message => "json/plain encoding failed: $@");
        }
        return Temporalio::Payload->new({
            metadata => { encoding => $self->encoding },
            data     => $data,
        });
    }

    method from_payload ($payload, $type_hint = undef) {
        my $value = eval { $json->decode($payload->data // 'null') };
        if ($@) {
            Temporalio::Exception::DataConverter->throw(
                message => "json/plain decoding failed: $@");
        }
        return $value;
    }
}

1;

__END__

=head1 NAME

Temporalio::Converter::Payload::Json - the json/plain catch-all encoding

=head1 DESCRIPTION

The catch-all converter: hashrefs, arrayrefs, JSON::PP boolean scalar
refs, and plain scalars that aren't bytes (UTF-8-flagged strings and
numbers — unflagged strings are claimed by
L<Temporalio::Converter::Payload::BinaryPlain> first). Serialization is
L<JSON::PP> in canonical mode with C<allow_blessed> off, so output is
deterministic and blessed objects are never silently stringified —
C<to_payload> declines blessed values (the composite then raises
L<Temporalio::Exception::DataConverter> naming the class). Encode/decode
failures raise L<Temporalio::Exception::DataConverter>. C<encoding>
returns C<json/plain>. See L<Temporalio::Converter::Payload> for the
converter contract.

=cut
