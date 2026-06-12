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
    }

    method bytes { $bytes }
}

1;

__END__

=head1 NAME

Temporalio::Payload::RawBytes - mark a scalar as raw bytes for conversion

=head1 SYNOPSIS

    use Temporalio::Payload::RawBytes;

    my $hint = Temporalio::Payload::RawBytes->new(bytes => $blob);
    my $payload = $converter->to_payload($hint);   # binary/plain

=head1 DESCRIPTION

Wraps a Perl scalar to tell L<Temporalio::Converter::Payload::BinaryPlain>
unambiguously that the value is raw bytes and must use the C<binary/plain>
encoding — useful when the scalar would otherwise be claimed by another
converter (for example a UTF-8-flagged string). C<bytes> returns the
wrapped scalar.

=cut
