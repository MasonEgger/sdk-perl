# ABOUTME: Hint wrapper selecting the binary/protobuf encoding for a generated
# ABOUTME: proto message (instead of the default json/protobuf form).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Exception::Argument ();

class Temporalio::Payload::BinaryProto {
    field $message :param;

    ADJUST {
        unless (Scalar::Util::blessed($message)
            && $message->can('descriptor')
            && $message->can('encode'))
        {
            Temporalio::Exception::Argument->throw(
                message => 'BinaryProto requires a generated proto message instance',
            );
        }
    }

    method message { $message }
}

1;

__END__

=head1 NAME

Temporalio::Payload::BinaryProto - select binary/protobuf for a proto message

=head1 SYNOPSIS

    use Temporalio::Payload::BinaryProto;

    my $hint = Temporalio::Payload::BinaryProto->new(message => $proto_msg);
    my $payload = $converter->to_payload($hint);   # binary/protobuf

=head1 DESCRIPTION

Wraps a generated C<Temporalio::Proto::*> message instance to tell
L<Temporalio::Converter::Payload::BinaryProtobuf> to serialize it in the
proto wire form (C<binary/protobuf> encoding) instead of the default
canonical-JSON form (C<json/protobuf>). C<message> returns the wrapped
message instance.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Payload::BinaryProto->new(
        message => ...,
    );

Constructs a Temporalio::Payload::BinaryProto. Named parameters:

=over 4

=item C<message>

(required)

=back

=head1 METHODS

=head2 message

Accessor returning the C<message> value.

=cut
