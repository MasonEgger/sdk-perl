# ABOUTME: Typed search-attribute collection (spec section 7.4) — an ordered
# ABOUTME: list of [SearchAttributeKey, value] pairs encoded into the
# ABOUTME: temporal.api.common.v1.SearchAttributes map. No untyped guessing.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Common::SearchAttributeKey ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();

class Temporalio::Common::TypedSearchAttributes {
    # $pairs: arrayref of [ SearchAttributeKey, $value ] pairs. A bare hashref
    # (or any non-arrayref) is rejected — spec section 7.4 forbids untyped
    # input and silent type guessing. The public constructor is positional
    # (`->new(\@pairs)`, spec section 7.4); a wrapper below translates it to
    # this named param before delegating to the generated constructor.
    field $pairs :param;

    ADJUST {
        unless (ref $pairs eq 'ARRAY') {
            Temporalio::Exception::Argument->throw(message =>
                'TypedSearchAttributes requires an arrayref of '
                . '[ SearchAttributeKey, value ] pairs; a bare/untyped '
                . 'hashref is not accepted (spec section 7.4 — no type guessing)');
        }
        for my $pair (@$pairs) {
            unless (ref $pair eq 'ARRAY' && @$pair == 2) {
                Temporalio::Exception::Argument->throw(message =>
                    'each search-attribute pair must be a '
                    . '[ SearchAttributeKey, value ] arrayref');
            }
            my $key = $pair->[0];
            unless (Scalar::Util::blessed($key)
                && $key->isa('Temporalio::Common::SearchAttributeKey')) {
                Temporalio::Exception::Argument->throw(message =>
                    'search-attribute key must be a '
                    . 'Temporalio::Common::SearchAttributeKey (no type guessing)');
            }
        }
    }

    method pairs { [ map { [ @$_ ] } @$pairs ] }

    # Encode every pair into a temporal.api.common.v1.SearchAttributes message
    # whose indexed_fields map name -> payload (with the SA type metadata).
    method to_proto {
        my $SearchAttributes = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.SearchAttributes');
        my %indexed_fields;
        for my $pair (@$pairs) {
            my ($key, $value) = @$pair;
            $indexed_fields{ $key->name } = $key->encode_value($value);
        }
        return $SearchAttributes->new({ indexed_fields => \%indexed_fields });
    }

    # _decode_fields($sa) -> (\@pairs, \%untyped): class method; the one
    # "decode a search attribute payload or skip" loop, shared by _from_proto
    # below and by Schedule::Action::StartWorkflow::_from_proto (which also
    # needs what was skipped). MUST-match sdk-python
    # converter/_search_attributes.py decode_typed_search_attributes
    # (:183-202): a field with no "type" metadata, an unrecognized type, or a
    # value that will not decode to the key's shape produces no pair. Every
    # such field lands in %untyped as the VERBATIM payload it arrived as, so a
    # caller that re-sends the collection loses nothing (F9 / GitHub issue #4);
    # the metadata map is read through `// {}` because a hand-built payload can
    # present an undef where the generated class auto-vivifies an empty map.
    sub _decode_fields ($class, $sa) {
        my $fields = (defined $sa ? $sa->indexed_fields : undef) // {};
        my (@pairs, %untyped);
        for my $name (sort keys %$fields) {
            my $payload       = $fields->{$name};
            my $metadata_type = ($payload->metadata // {})->{type};
            my $key           = defined $metadata_type
                ? Temporalio::Common::SearchAttributeKey->_from_metadata_type(
                    $name, $metadata_type)
                : undef;
            my @value = defined $key ? $key->_decode_value_or_skip($payload) : ();
            if (@value) {
                push @pairs, [ $key, $value[0] ];
            }
            else {
                $untyped{$name} = $payload;
            }
        }
        return (\@pairs, \%untyped);
    }

    # _from_proto($sa): class method; the inverse of to_proto. Keeps only the
    # fields _decode_fields could type; a caller that must also carry the rest
    # forward calls _decode_fields directly. Undef/empty input decodes to an
    # empty collection, mirroring TypedSearchAttributes.empty.
    sub _from_proto ($class, $sa) {
        my ($pairs) = $class->_decode_fields($sa);
        return $class->new($pairs);
    }
}

# Spec section 7.4 mandates the positional constructor `->new(\@pairs)`.
# `feature 'class'` only generates a named-param `new`, so wrap it: capture the
# generated constructor, then expose a positional `new` that delegates. A bare
# untyped hashref (or any non-arrayref) is rejected here before delegation —
# the ADJUST block re-validates pair shape and key types.
{
    no warnings 'redefine';
    my $generated = Temporalio::Common::TypedSearchAttributes->can('new');
    *Temporalio::Common::TypedSearchAttributes::new = sub ($class, $pairs = undef) {
        unless (ref $pairs eq 'ARRAY') {
            Temporalio::Exception::Argument->throw(message =>
                'TypedSearchAttributes->new requires an arrayref of '
                . '[ SearchAttributeKey, value ] pairs; a bare/untyped '
                . 'hashref is not accepted (spec section 7.4 — no type guessing)');
        }
        return $generated->($class, pairs => $pairs);
    };
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::TypedSearchAttributes - typed search-attribute collection

=head1 SYNOPSIS

    use Temporalio::Common::SearchAttributeKey;
    use Temporalio::Common::TypedSearchAttributes;

    my $tsa = Temporalio::Common::TypedSearchAttributes->new([
        [ Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField') => 'x' ],
        [ Temporalio::Common::SearchAttributeKey->int('CustomIntField')         => 42 ],
    ]);

    my $proto = $tsa->to_proto;   # temporal.api.common.v1.SearchAttributes

=head1 DESCRIPTION

An ordered collection of typed search-attribute pairs (spec section 7.4).
The constructor takes an arrayref of C<[ SearchAttributeKey, value ]>
pairs; C<to_proto> encodes each value (via the key's C<encode_value>) into
the C<indexed_fields> map of a C<temporal.api.common.v1.SearchAttributes>
message.

v0.1 accepts only typed input. A bare untyped hashref — or any pair whose
key is not a L<Temporalio::Common::SearchAttributeKey> — raises
L<Temporalio::Exception::Argument>: there is no silent type guessing (spec
section 7.4).

Decoding is the forgiving direction. A field whose payload carries no
recognized C<type> metadata, or a value that will not decode to that type's
shape, is skipped rather than raised on, matching sdk-python's
C<decode_typed_search_attributes>. Callers that must not lose such a field (a
schedule action rebuilding itself from a describe response, say) read both
halves through the internal C<_decode_fields>, which returns the typed pairs
and the skipped fields as their verbatim payloads. See
L<Temporalio::Schedule::Action/Search attributes the SDK cannot type>.

=head1 METHODS

=head2 pairs

Returns the list of contained [key, value] pairs.

=head2 to_proto

Builds and returns the C<temporal.api.common.v1.SearchAttributes> proto message from the contained key/value pairs.

=cut
