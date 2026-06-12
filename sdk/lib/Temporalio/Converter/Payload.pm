# ABOUTME: Abstract payload-converter base plus the default composite that
# ABOUTME: tries the five Temporal-spec encodings in order (spec section 5.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Exception::DataConverter ();
use Temporalio::Exception::Runtime ();

class Temporalio::Converter::Payload {
    field $converters :param = [];
    field %by_encoding;    # encoding string -> first converter claiming it

    ADJUST {
        # Reverse order so that on a duplicate encoding the FIRST registered
        # converter wins the from_payload dispatch (T-pay-5).
        %by_encoding = map { $_->encoding => $_ } reverse @$converters;
    }

    # The default composite: the five spec encodings in Temporal-spec order.
    sub default ($class) {
        require Temporalio::Converter::Payload::BinaryNull;
        require Temporalio::Converter::Payload::BinaryPlain;
        require Temporalio::Converter::Payload::JsonProtobuf;
        require Temporalio::Converter::Payload::BinaryProtobuf;
        require Temporalio::Converter::Payload::Json;
        return $class->new(converters => [
            Temporalio::Converter::Payload::BinaryNull->new,
            Temporalio::Converter::Payload::BinaryPlain->new,
            Temporalio::Converter::Payload::JsonProtobuf->new,
            Temporalio::Converter::Payload::BinaryProtobuf->new,
            Temporalio::Converter::Payload::Json->new,
        ]);
    }

    # Composite: first converter to return a defined Payload wins. Subclasses
    # override with their single-encoding implementation.
    method to_payload ($value) {
        for my $converter (@$converters) {
            my $payload = $converter->to_payload($value);
            return $payload if defined $payload;
        }
        my $type =
              Scalar::Util::blessed($value) ? Scalar::Util::blessed($value)
            : ref $value                    ? ref($value) . ' reference'
            : defined $value                ? 'non-reference scalar'
            :                                 'undef';
        Temporalio::Exception::DataConverter->throw(
            message => "no payload converter handled a value of type $type");
    }

    # Composite: dispatch on the payload's encoding metadata. Subclasses
    # override with their single-encoding implementation.
    method from_payload ($payload, $type_hint = undef) {
        my $encoding  = $payload->metadata->{encoding} // '';
        my $converter = $by_encoding{$encoding}
            or Temporalio::Exception::DataConverter->throw(
                message => "no payload converter for encoding '$encoding'");
        return $converter->from_payload($payload, $type_hint);
    }

    # Abstract: a composite has no single encoding; subclasses return theirs.
    method encoding {
        Temporalio::Exception::Runtime->throw(
            message => 'encoding must be implemented by a '
                . 'Temporalio::Converter::Payload subclass');
    }
}

1;

__END__

=head1 NAME

Temporalio::Converter::Payload - payload converter base class and composite

=head1 SYNOPSIS

    use Temporalio::Converter::Payload;

    my $pc = Temporalio::Converter::Payload->default;

    my $payload = $pc->to_payload({ a => 1 });        # json/plain
    my $value   = $pc->from_payload($payload);        # { a => 1 }

    # Custom converters: first registered wins.
    my $custom = Temporalio::Converter::Payload->new(
        converters => [ My::Converter->new, @defaults ],
    );

=head1 DESCRIPTION

The abstract base class every encoding converter subclasses, and — when
constructed with a C<converters> list — the composite that the SDK uses as
its default payload converter.

C<default> composes the five Temporal-spec encodings in the spec-mandated
order: L<Temporalio::Converter::Payload::BinaryNull> (C<binary/null>),
L<Temporalio::Converter::Payload::BinaryPlain> (C<binary/plain>),
L<Temporalio::Converter::Payload::JsonProtobuf> (C<json/protobuf>),
L<Temporalio::Converter::Payload::BinaryProtobuf> (C<binary/protobuf>),
then L<Temporalio::Converter::Payload::Json> (C<json/plain>) as the
catch-all.

=head1 METHODS

=head2 to_payload($value)

Composite: tries each registered converter in order; the first to return a
defined L<Temporalio::Payload> wins. Raises
L<Temporalio::Exception::DataConverter> naming the value's type when no
converter handles it. Subclasses override this with their single-encoding
implementation, returning C<undef> for values they do not handle.

=head2 from_payload($payload, $type_hint = undef)

Composite: dispatches on the payload's C<encoding> metadata to the matching
registered converter (first registered wins on duplicates). Raises
L<Temporalio::Exception::DataConverter> for an unknown encoding.

=head2 encoding

Abstract — each subclass returns its Temporal-spec encoding string. The
composite itself has no single encoding and raises
L<Temporalio::Exception::Runtime>.

=head2 default

Class method returning the default composite described above.

=cut
