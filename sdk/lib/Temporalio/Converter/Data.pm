# ABOUTME: Top-level data-conversion facade: payload converter + failure
# ABOUTME: converter + ordered payload codec chain (spec section 5.1).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Core::Proto ();
use Temporalio::Converter::Payload;
use Temporalio::Converter::Failure;
use Temporalio::Exception::DataConverter ();

my $FAILURE = Temporalio::Core::Proto::resolve('temporal.api.failure.v1.Failure');

# Which failure_info variants embed a Payloads message the codec chain must
# transform, and under which field. Mirrors the reference SDKs' traversal
# (sdk-python _apply_to_failure_payloads): these four variants plus
# encoded_attributes, recursively through the cause chain.
my %FAILURE_PAYLOADS_FIELD = (
    application_failure_info    => 'details',
    timeout_failure_info        => 'last_heartbeat_details',
    canceled_failure_info       => 'details',
    reset_workflow_failure_info => 'last_heartbeat_details',
);

class Temporalio::Converter::Data {
    field $payload_converter :param = undef;
    field $failure_converter :param = undef;
    field $payload_codecs    :param = [];

    ADJUST {
        $payload_converter //= Temporalio::Converter::Payload->default;
        $failure_converter //= Temporalio::Converter::Failure->default;
    }

    method payload_converter { $payload_converter }
    method failure_converter { $failure_converter }
    method payload_codecs    { $payload_codecs }

    # Spec section 5.1 failure modes: whatever a codec or converter raises
    # surfaces as DataConverter — an existing DataConverter propagates as-is,
    # another Temporalio exception becomes the cause, anything else (plain
    # string deaths, foreign objects) is folded into the message.
    sub _propagate_as_data_converter ($error, $what) {
        die $error
            if Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::DataConverter');
        if (Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception'))
        {
            Temporalio::Exception::DataConverter->throw(
                message => "$what failed",
                cause   => $error,
            );
        }
        my $message = "$error";
        chomp $message;
        Temporalio::Exception::DataConverter->throw(
            message => "$what failed: $message");
    }

    # codec_encode / codec_decode (\@payloads) -> Future(\@payloads): apply ONLY
    # the codec chain over a list of Payloads, no value conversion. The workflow
    # worker boundary (spec section 8.3 steps 5 + 8) encodes/decodes the payloads
    # embedded in an activation/completion while the runner handles value
    # conversion with the bare payload_converter. A no-codec converter passes the
    # list through unchanged.
    async method codec_encode ($payloads) {
        return $payloads unless @$payload_codecs;
        return await $self->_run_codecs(encode => $payloads);
    }

    async method codec_decode ($payloads) {
        return $payloads unless @$payload_codecs;
        return await $self->_run_codecs(decode => $payloads);
    }

    # Run the codec chain over an arrayref of Payloads. Ordering is part of
    # the Temporal spec: encode applies codecs in list order, decode applies
    # them in REVERSE (the last codec on encode is the first on decode).
    async method _run_codecs ($direction, $payloads) {
        my @codecs = $direction eq 'encode'
            ? @$payload_codecs
            : reverse @$payload_codecs;
        for my $codec (@codecs) {
            $payloads = await $codec->$direction($payloads);
        }
        return $payloads;
    }

    # Apply the codec chain to every payload embedded in a Failure, in place:
    # encoded_attributes, the details/last_heartbeat_details of the variants
    # that carry them, then recursively the cause chain.
    async method _apply_codecs_to_failure ($failure, $direction) {
        if (defined(my $attributes = $failure->encoded_attributes)) {
            my $wrapped = await $self->_run_codecs($direction, [$attributes]);
            $failure->set_encoded_attributes($wrapped->[0]);
        }
        my $which = $failure->which_failure_info // '';
        if (my $field = $FAILURE_PAYLOADS_FIELD{$which}) {
            my $payloads_msg = $failure->$which->$field;
            if (defined $payloads_msg) {
                my $list = $payloads_msg->payloads;    # live arrayref
                @$list = @{ await $self->_run_codecs($direction, [@$list]) };
            }
        }
        if (defined(my $cause = $failure->cause)) {
            await $self->_apply_codecs_to_failure($cause, $direction);
        }
        return;
    }

    # \@values -> list of Payloads: convert each value, then codec-encode.
    async method to_payloads ($values) {
        my @payloads;
        try {
            @payloads = map { $payload_converter->to_payload($_) } @$values;
            @payloads = @{ await $self->_run_codecs(encode => \@payloads) }
                if @$payload_codecs;
        }
        catch ($error) {
            _propagate_as_data_converter($error, 'payload encoding');
        }
        return @payloads;
    }

    # \@payloads (+ optional \@type_hints) -> list of values: codec-decode
    # (reverse order), then convert each payload.
    async method from_payloads ($payloads, $type_hints = undef) {
        my @values;
        try {
            my @decoded = @$payloads;
            @decoded = @{ await $self->_run_codecs(decode => \@decoded) }
                if @$payload_codecs;
            @values = map {
                $payload_converter->from_payload($decoded[$_],
                    $type_hints ? $type_hints->[$_] : undef)
            } 0 .. $#decoded;
        }
        catch ($error) {
            _propagate_as_data_converter($error, 'payload decoding');
        }
        return @values;
    }

    # Exception -> Failure proto, embedded payloads codec-encoded.
    async method to_failure ($exception) {
        my $failure =
            $failure_converter->to_failure($exception, $payload_converter);
        if (@$payload_codecs) {
            try {
                # Normalize through the wire so every nested field is a
                # materialized instance the traversal can mutate in place.
                $failure = $FAILURE->decode($failure->encode);
                await $self->_apply_codecs_to_failure($failure, 'encode');
            }
            catch ($error) {
                _propagate_as_data_converter($error,
                    'failure payload encoding');
            }
        }
        return $failure;
    }

    # Failure proto -> exception, embedded payloads codec-decoded first. The
    # caller's proto is never mutated — the codec chain runs on a copy.
    async method from_failure ($failure) {
        if (@$payload_codecs) {
            try {
                $failure = $FAILURE->decode($failure->encode);
                await $self->_apply_codecs_to_failure($failure, 'decode');
            }
            catch ($error) {
                _propagate_as_data_converter($error,
                    'failure payload decoding');
            }
        }
        return $failure_converter->from_failure($failure, $payload_converter);
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Converter::Data - the top-level data conversion facade

=head1 SYNOPSIS

    use Temporalio::Converter::Data;

    my $dc = Temporalio::Converter::Data->new(
        payload_converter => $pc,      # default: Temporalio::Converter::Payload->default
        failure_converter => $fc,      # default: Temporalio::Converter::Failure->default
        payload_codecs    => [ ... ],  # default []
    );

    my @payloads  = await $dc->to_payloads(\@values);
    my @values    = await $dc->from_payloads(\@payloads, \@type_hints);
    my $failure   = await $dc->to_failure($exception);
    my $exception = await $dc->from_failure($failure);

=head1 DESCRIPTION

The single data-conversion object handed to the client and worker (spec
section 5.1). It composes a L<Temporalio::Converter::Payload>, a
L<Temporalio::Converter::Failure>, and an ordered list of
L<Temporalio::Converter::PayloadCodec> instances.

B<Codec ordering matters and is part of the Temporal spec>: on encode the
codecs run in list order (first codec first); on decode they run in
B<reverse> (last codec first). Getting this wrong silently corrupts
payloads once two codecs are stacked — this class is the only place the
ordering is applied.

All four conversion methods are asynchronous (L<Future::AsyncAwait>) and
resolve to lists, because codecs are allowed to be asynchronous
(encryption services, compression pools).

=head1 METHODS

=head2 to_payloads(\@values)

Converts each value through the payload converter, then applies the codec
chain in order. Resolves to the list of Payloads.

=head2 from_payloads(\@payloads, \@type_hints?)

Applies the codec chain in reverse, then converts each payload back to a
value (passing the positionally matching type hint, if any). Resolves to
the list of values.

=head2 to_failure($exception)

Converts the exception through the failure converter, then codec-encodes
the Failure's embedded payloads: C<encoded_attributes> plus the
C<details>/C<last_heartbeat_details> of the variants that carry them,
recursively through the C<cause> chain — the same traversal as the
reference SDKs. Resolves to the Failure proto.

=head2 from_failure($failure)

Codec-decodes the embedded payloads (on a copy — the caller's proto is
not mutated), then converts through the failure converter. Resolves to
the L<Temporalio::Exception> instance.

=head2 payload_converter / failure_converter / payload_codecs

Readers for the composed parts.

=head1 FAILURE MODES

A raising codec or payload converter propagates as
L<Temporalio::Exception::DataConverter>: an existing DataConverter
passes through unchanged, another Temporalio exception is attached as
the C<cause>, and anything else is folded into the message.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Converter::Data->new(
        payload_converter => ...,
        failure_converter => ...,
        payload_codecs => ...,
    );

Constructs a Temporalio::Converter::Data. Named parameters:

=over 4

=item C<payload_converter>

(optional, default C<undef>)

=item C<failure_converter>

(optional, default C<undef>)

=item C<payload_codecs>

(optional, default C<[]>)

=back

=head1 METHODS

=head2 codec_decode

Async. Decodes payloads through the configured payload codec, returning a L<Future> of the decoded payloads.

=head2 codec_encode

Async. Encodes payloads through the configured L<Temporalio::Converter::PayloadCodec>, returning a L<Future> of the encoded payloads.

=cut
