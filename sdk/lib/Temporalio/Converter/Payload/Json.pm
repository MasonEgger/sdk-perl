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
        my $data = $payload->data;
        # Finding ADJ1 (spec R58): empty payload data never reaches the JSON
        # parser raw. sdk-python raises on the same payload (json.loads(b'')
        # dies, wrapped as RuntimeError "Failed parsing"), so the typed error
        # is the parity direction. An unset proto bytes field is Python's
        # b'', so undef data gets the same treatment as the empty string.
        unless (defined $data && length $data) {
            Temporalio::Exception::DataConverter->throw(
                message => 'json/plain payload has empty data');
        }
        my $value = eval { $json->decode($data) };
        if ($@) {
            Temporalio::Exception::DataConverter->throw(
                message => "json/plain decoding failed: $@");
        }
        return $value;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Converter::Payload::Json - the json/plain catch-all encoding

=head1 DESCRIPTION

The catch-all converter: hashrefs, arrayrefs, JSON::PP boolean scalar
refs, and every plain non-reference scalar, strings (with or without the
internal UTF-8 flag) and numbers alike (spec R59: bare scalars are never
claimed as bytes; wrap bytes in L<Temporalio::Payload::RawBytes> to
target C<binary/plain>). Serialization is L<JSON::PP> in canonical mode
with C<allow_blessed> off, so output is deterministic and blessed
objects are never silently stringified: C<to_payload> declines blessed
values (the composite then raises
L<Temporalio::Exception::DataConverter> naming the class). Encode/decode
failures raise L<Temporalio::Exception::DataConverter>, as does a
payload whose data is empty or unset (spec R58, matching sdk-python,
which raises on the same payload). C<encoding> returns C<json/plain>.
See L<Temporalio::Converter::Payload> for the converter contract.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Converter::Payload::Json.

=cut
