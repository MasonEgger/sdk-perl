# ABOUTME: Payload converter for BinaryProto-hinted proto messages in wire form
# ABOUTME: — the Temporal-spec binary/protobuf encoding (spec section 5.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Converter::Payload;
use Temporalio::Core::Proto ();
use Temporalio::Exception::DataConverter ();
use Temporalio::Payload ();
use Temporalio::Payload::BinaryProto ();

class Temporalio::Converter::Payload::BinaryProtobuf
    :isa(Temporalio::Converter::Payload)
{
    method encoding { 'binary/protobuf' }

    method to_payload ($value) {
        return undef
            unless Scalar::Util::blessed($value)
            && $value->isa('Temporalio::Payload::BinaryProto');

        my $message = $value->message;
        return Temporalio::Payload->new({
            metadata => {
                encoding    => $self->encoding,
                messageType => $message->descriptor->full_name,
            },
            data => $message->encode,
        });
    }

    method from_payload ($payload, $type_hint = undef) {
        my $full_name = $payload->metadata->{messageType};
        unless (defined $full_name && length $full_name) {
            Temporalio::Exception::DataConverter->throw(
                message => 'binary/protobuf payload is missing messageType metadata');
        }
        my $class = Temporalio::Core::Proto::resolve($full_name);
        return $class->decode($payload->data // '');
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Converter::Payload::BinaryProtobuf - the binary/protobuf encoding

=head1 DESCRIPTION

Handles generated proto messages wrapped in the
L<Temporalio::Payload::BinaryProto> hint. C<to_payload> serializes the
wrapped message to its proto wire form, setting C<messageType> metadata to
the full proto type name. C<from_payload> resolves C<messageType> back to
the generated class via L<Temporalio::Core::Proto> and decodes the wire
bytes (returning the message itself, not the hint wrapper), raising
L<Temporalio::Exception::DataConverter> when the metadata is missing.
C<encoding> returns C<binary/protobuf>. See
L<Temporalio::Converter::Payload> for the converter contract.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Converter::Payload::BinaryProtobuf.

=cut
