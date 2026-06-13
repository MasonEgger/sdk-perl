# ABOUTME: The payload record (metadata map + data bytes) used by all payload
# ABOUTME: converters — a transparent subclass of the real generated proto class.
package Temporalio::Payload;

use v5.38;
use warnings;

use Temporalio::Core::Proto ();

# NOT a hand-rolled struct: Temporalio::Payload IS the generated
# temporal.api.common.v1.Payload message class (spec section 5.2's "Payload"),
# re-exposed under a stable SDK-level name. Resolving the parent triggers the
# one-time vendored-proto load, so requiring this module implies proto load.
our @ISA;    ## no critic (ProhibitExplicitISA)
BEGIN {
    @ISA = (Temporalio::Core::Proto::resolve('temporal.api.common.v1.Payload'));
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Payload - the Temporal payload record (metadata + data)

=head1 SYNOPSIS

    use Temporalio::Payload;

    my $payload = Temporalio::Payload->new({
        metadata => { encoding => 'json/plain' },
        data     => '{"a":1}',
    });

    my $encoding = $payload->metadata->{encoding};
    my $bytes    = $payload->data;

=head1 DESCRIPTION

A transparent subclass of the generated C<temporal.api.common.v1.Payload>
proto message class (see L<Temporalio::Core::Proto>), giving the SDK a
stable name for the payload record that L<Temporalio::Converter::Payload>
produces and consumes. Instances carry the proto's C<metadata> map
(string to bytes; always includes the C<encoding> key) and C<data> bytes,
and inherit C<encode>/C<decode>/C<to_hashref> from the generated class.

Payloads materialized from the wire inside other messages are instances of
the generated parent class, not of this subclass — converters therefore
duck-type on the C<metadata>/C<data> accessors rather than C<isa> checks.

Requiring this module triggers the one-time vendored proto load.

=cut
