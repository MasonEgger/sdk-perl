# ABOUTME: Payload converter for generated proto messages in proto3 canonical
# ABOUTME: JSON form — the Temporal-spec json/protobuf encoding (spec section 5.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Converter::Payload;
use Temporalio::Core::Proto ();
use Temporalio::Exception::DataConverter ();
use Temporalio::Payload ();

class Temporalio::Converter::Payload::JsonProtobuf
    :isa(Temporalio::Converter::Payload)
{
    method encoding { 'json/protobuf' }

    method to_payload ($value) {
        return undef
            unless Scalar::Util::blessed($value)
            && $value->can('descriptor')
            && $value->can('to_hashref');

        my $full_name = $value->descriptor->full_name;
        my $json = Temporalio::Core::Proto::json()
            ->encode($full_name, $value->to_hashref);
        utf8::encode($json) if utf8::is_utf8($json);

        return Temporalio::Payload->new({
            metadata => {
                encoding    => $self->encoding,
                messageType => $full_name,
            },
            data => $json,
        });
    }

    method from_payload ($payload, $type_hint = undef) {
        my $full_name = $payload->metadata->{messageType};
        unless (defined $full_name && length $full_name) {
            Temporalio::Exception::DataConverter->throw(
                message => 'json/protobuf payload is missing messageType metadata');
        }
        my $class = Temporalio::Core::Proto::resolve($full_name);

        my $data = $payload->data // '';
        # Protobuf::JSON expects character data. Finding L23 (spec R57):
        # utf8::decode returns false on malformed UTF-8 and leaves the bytes
        # untouched, which used to sail through as latin-1 mojibake (probe
        # verify-45/pool-payload/probe_cause_mojibake.pl, shared with R68).
        unless (utf8::decode($data)) {
            Temporalio::Exception::DataConverter->throw(
                message => 'json/protobuf payload data is not valid UTF-8');
        }
        # Finding ADJ1 (spec R58): parser deaths (empty data included) must
        # not escape raw; sdk-python wraps the ParseError the same way
        # (RuntimeError "Failed parsing").
        my $values =
            eval { Temporalio::Core::Proto::json()->decode($full_name, $data) };
        if ($@) {
            my $message = "$@";
            chomp $message;
            Temporalio::Exception::DataConverter->throw(
                message => "json/protobuf decoding failed: $message");
        }

        # Materialize nested message fields into generated-class instances by
        # round-tripping the plain decoded hashref through the wire form.
        return $class->decode($class->new($values)->encode);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Converter::Payload::JsonProtobuf - the json/protobuf encoding

=head1 DESCRIPTION

Handles generated C<Temporalio::Proto::*> message instances (detected via
the C<descriptor> method the class generator installs). C<to_payload>
serializes the message to proto3 canonical JSON through the shared
L<Protobuf::JSON> codec, setting C<messageType> metadata to the full proto
type name from C<< $value->descriptor->full_name >>. C<from_payload>
resolves C<messageType> back to the generated class via
L<Temporalio::Core::Proto> and materializes a fully-blessed instance,
raising L<Temporalio::Exception::DataConverter> when the metadata is
missing, when the payload data is not valid UTF-8 (spec R57), or when
the JSON parse fails, empty data included (spec R58, matching
sdk-python's typed wrap of the parse error). C<encoding> returns
C<json/protobuf>. See
L<Temporalio::Converter::Payload> for the converter contract.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Converter::Payload::JsonProtobuf.

=cut
