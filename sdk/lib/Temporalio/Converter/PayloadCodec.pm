# ABOUTME: Abstract base class for payload codecs — byte-level transforms
# ABOUTME: such as encryption or compression (spec section 5.4).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Exception::Runtime ();

class Temporalio::Converter::PayloadCodec {

    # Abstract: arrayref of Payloads -> Future resolving to an arrayref of
    # Payloads. Implementations may change the payload count (at least one,
    # no more than given) — the reference SDKs allow batching codecs.
    async method encode ($payloads) {
        Temporalio::Exception::Runtime->throw(
            message => 'encode must be implemented by a '
                . 'Temporalio::Converter::PayloadCodec subclass');
    }

    # Abstract: the inverse of encode, same shape.
    async method decode ($payloads) {
        Temporalio::Exception::Runtime->throw(
            message => 'decode must be implemented by a '
                . 'Temporalio::Converter::PayloadCodec subclass');
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Converter::PayloadCodec - abstract payload codec base class

=head1 SYNOPSIS

    use feature 'class';
    no warnings 'experimental::class';
    use Future::AsyncAwait;
    use Temporalio::Converter::PayloadCodec;

    class My::Codec :isa(Temporalio::Converter::PayloadCodec) {
        async method encode ($payloads) { ... }   # arrayref -> arrayref
        async method decode ($payloads) { ... }   # arrayref -> arrayref
    }

    my $dc = Temporalio::Converter::Data->new(
        payload_codecs => [ My::Codec->new ],
    );

=head1 DESCRIPTION

The abstract base every payload codec subclasses (spec section 5.4).
Codecs transform payload bytes on the wire — encryption and compression
are the typical uses — and are stacked via
L<Temporalio::Converter::Data>'s C<payload_codecs> list.

B<Ordering is part of the Temporal spec>: encode applies codecs in list
order (the first codec runs first), decode applies them in B<reverse>
(the last codec runs first). L<Temporalio::Converter::Data> enforces
this; codecs themselves only see their own step.

Codecs typically produce a new Payload whose C<metadata.encoding> names
the wrapper encoding (for example C<binary/encrypted>) with the original
payload's serialized bytes inside C<data>; C<decode> unwraps accordingly
and must pass through payloads it does not recognize.

=head1 WORKER CODEC BOUNDARY

On the workflow worker, L<Temporalio::Worker::WorkflowDispatcher> applies
the codec chain to B<every> payload crossing the worker boundary — decode
on the inbound activation, encode on the outbound completion (spec R7,
finding R6). The covered surfaces:

=over

=item * workflow, signal, query, and update inputs (arguments and headers)

=item * activity, local-activity, child-workflow, and nexus operation
results

=item * failure payloads (C<details>, C<last_heartbeat_details>, and
C<encoded_attributes>, recursively through the C<cause> chain)

=item * memo and header payloads, inbound and outbound

=item * workflow results, update and query responses

=item * continue-as-new, activity, local-activity, child-workflow, nexus,
and signal-external outbound arguments (with their memo and headers)

=item * memo upserts (C<ModifyWorkflowProperties>)

=back

B<Search attributes are the deliberate exception>: payloads inside a
C<temporal.api.common.v1.SearchAttributes> message (start-time SAs,
child-workflow and continue-as-new SAs, and SA upserts) are never offered
to the codec chain in either direction — the server must be able to index
their values. This matches sdk-python's C<skip_search_attributes>
traversal.

=head1 METHODS

Both methods are asynchronous (L<Future::AsyncAwait>), take an arrayref
of C<temporal.api.common.v1.Payload> instances, and resolve to an
arrayref of Payloads. The result may change the payload count — at least
one, no more than were given. The base implementations raise
L<Temporalio::Exception::Runtime>; subclasses must override both.

=head2 encode($payloads)

Transform outbound payloads.

=head2 decode($payloads)

Invert C<encode> on inbound payloads.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Converter::PayloadCodec.

=cut
