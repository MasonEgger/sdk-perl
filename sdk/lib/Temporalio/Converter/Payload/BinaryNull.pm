# ABOUTME: Payload converter for undef values — the Temporal-spec binary/null
# ABOUTME: encoding with an empty data field (spec section 5.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Converter::Payload;
use Temporalio::Exception::DataConverter ();
use Temporalio::Payload ();

class Temporalio::Converter::Payload::BinaryNull
    :isa(Temporalio::Converter::Payload)
{
    method encoding { 'binary/null' }

    method to_payload ($value) {
        return undef if defined $value;
        return Temporalio::Payload->new({
            metadata => { encoding => $self->encoding },
        });
    }

    method from_payload ($payload, $type_hint = undef) {
        if (length($payload->data // '')) {
            Temporalio::Exception::DataConverter->throw(
                message => 'expected empty data for a binary/null payload');
        }
        return undef;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Converter::Payload::BinaryNull - the binary/null encoding

=head1 DESCRIPTION

Handles C<undef> values: C<to_payload> returns a payload with encoding
C<binary/null> and no data (and C<undef> for any defined value);
C<from_payload> returns C<undef>, raising
L<Temporalio::Exception::DataConverter> if the payload unexpectedly
carries data. C<encoding> returns C<binary/null>. See
L<Temporalio::Converter::Payload> for the converter contract.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Converter::Payload::BinaryNull.

=cut
