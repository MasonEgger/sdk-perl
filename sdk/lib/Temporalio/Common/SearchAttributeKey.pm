# ABOUTME: Typed search-attribute key (spec section 7.4) — the MUST-match
# ABOUTME: SearchAttributeKey type system and its payload (metadata.type)
# ABOUTME: encoding, mirroring sdk-python temporalio/common.py + converter.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use JSON::PP ();
use Temporalio::Common::SearchAttributeUpdate ();
use Temporalio::Exception::Argument ();
use Temporalio::Payload ();

class Temporalio::Common::SearchAttributeKey {
    # name           -> the server-side attribute name (map key)
    # metadata_type  -> the PascalCase "type" metadata on the payload
    #                   (Keyword/Text/Int/Double/Bool/Datetime/KeywordList).
    #                   MUST match sdk-python SearchAttributeKey._metadata_type.
    # indexed_value_type -> the temporal.api.enums.v1.IndexedValueType number.
    field $name               :param;
    field $metadata_type      :param;
    field $indexed_value_type :param;

    method name               { $name }
    method metadata_type      { $metadata_type }
    method indexed_value_type { $indexed_value_type }

    # ---- Factory methods. IndexedValueType numbers MUST match the proto enum:
    # TEXT 1, KEYWORD 2, INT 3, DOUBLE 4, BOOL 5, DATETIME 6, KEYWORD_LIST 7.
    sub text ($class, $name) {
        $class->new(
            name => $name, metadata_type => 'Text', indexed_value_type => 1);
    }

    sub keyword ($class, $name) {
        $class->new(
            name => $name, metadata_type => 'Keyword', indexed_value_type => 2);
    }

    sub int ($class, $name) {
        $class->new(
            name => $name, metadata_type => 'Int', indexed_value_type => 3);
    }

    sub double ($class, $name) {
        $class->new(
            name => $name, metadata_type => 'Double', indexed_value_type => 4);
    }

    sub bool ($class, $name) {
        $class->new(
            name => $name, metadata_type => 'Bool', indexed_value_type => 5);
    }

    sub datetime ($class, $name) {
        $class->new(
            name => $name, metadata_type => 'Datetime', indexed_value_type => 6);
    }

    sub keyword_list ($class, $name) {
        $class->new(name => $name, metadata_type => 'KeywordList',
            indexed_value_type => 7);
    }

    # Maps a stored payload "type" metadata string back to the factory method
    # that built it (the reverse of the seven factories above). MUST-match
    # sdk-python SearchAttributeKey._from_metadata_type (common.py:524-541):
    # the type metadata is usually the PascalCase form (e.g. "KeywordList")
    # but the server rarely emits the SCREAMING_SNAKE_CASE
    # temporal.api.enums.v1.IndexedValueType name instead (e.g.
    # "INDEXED_VALUE_TYPE_KEYWORD_LIST"), so both forms map to the same
    # factory. An unrecognized type is ignored (returns undef), never an
    # exception; this stays forward-compatible with a server-added SA type
    # this SDK doesn't know yet.
    my %FACTORY_METHOD_FOR_TYPE = (
        Text        => 'text',
        Keyword     => 'keyword',
        Int         => 'int',
        Double      => 'double',
        Bool        => 'bool',
        Datetime    => 'datetime',
        KeywordList => 'keyword_list',

        INDEXED_VALUE_TYPE_TEXT         => 'text',
        INDEXED_VALUE_TYPE_KEYWORD      => 'keyword',
        INDEXED_VALUE_TYPE_INT          => 'int',
        INDEXED_VALUE_TYPE_DOUBLE       => 'double',
        INDEXED_VALUE_TYPE_BOOL         => 'bool',
        INDEXED_VALUE_TYPE_DATETIME     => 'datetime',
        INDEXED_VALUE_TYPE_KEYWORD_LIST => 'keyword_list',
    );

    # _from_metadata_type($name, $metadata_type): class method.
    sub _from_metadata_type ($class, $name, $metadata_type) {
        my $method = $FACTORY_METHOD_FOR_TYPE{ $metadata_type // '' };
        return undef unless $method;
        return $class->$method($name);
    }

    # decode_value($payload): the inverse of encode_value. JSON-decodes the
    # payload data, then undoes the Bool normalization (JSON true/false ->
    # 1/0). Always json/plain (encode_value never uses any other encoding,
    # spec section 7.4), so decode needs no data-converter/codec chain. This is
    # the strict form: a payload this key did not encode (another encoding,
    # malformed data) dies. The wire-decode path uses _decode_value_or_skip.
    method decode_value ($payload) {
        my $json = JSON::PP->new->allow_nonref(1)->utf8(1);
        my $value = $json->decode($payload->data);
        return $metadata_type eq 'Bool' ? ($value ? 1 : 0) : $value;
    }

    # _decode_value_or_skip($payload) -> (value), or the empty list when the
    # field must be skipped. The forgiving counterpart of decode_value, used by
    # the wire-decode loop in TypedSearchAttributes::_decode_fields, where a
    # value the server indexed under some other convention must never take the
    # whole decode down. MUST-match sdk-python
    # converter/_search_attributes.py decode_typed_search_attributes
    # (:183-202): a value that will not decode is ignored, a list value for a
    # non-KeywordList key yields its single element (or is ignored when it
    # holds anything other than one), and a value whose type does not match the
    # key is ignored. Python's final check is an isinstance against the key's
    # origin_value_type; a Perl scalar carries no comparable str/int/float
    # distinction, so the check here covers what Perl can tell apart: decode
    # failure, list-versus-scalar shape, a JSON object where a scalar belongs,
    # and Bool (which must be a JSON boolean, not any truthy scalar).
    method _decode_value_or_skip ($payload) {
        return () unless $payload->can('data');
        my $data = $payload->data;
        return () unless defined $data;

        my $value;
        {
            local $@;
            my $decoded = eval {
                JSON::PP->new->allow_nonref(1)->utf8(1)->decode($data);
            };
            return () if $@;
            $value = $decoded;
        }

        if ($metadata_type eq 'KeywordList') {
            return () unless ref $value eq 'ARRAY';
            # The skip rule has to be at least as strict as the re-encode
            # (_normalize), so both call the one predicate: a list this decode
            # admits but encode_value would reject lands in the typed
            # collection and then dies on the next update (F9).
            return () if grep { !_is_keyword_list_element($_) } @$value;
            return ($value);
        }
        if (ref $value eq 'ARRAY') {
            return () unless @$value == 1;
            $value = $value->[0];
        }
        if ($metadata_type eq 'Bool') {
            return () unless ref $value eq 'JSON::PP::Boolean';
            return ($value ? 1 : 0);
        }
        return () if ref $value || !defined $value;
        return ($value);
    }

    # value_set($value) -> a Temporalio::Common::SearchAttributeUpdate that sets
    # this key to $value (spec section 24; MUST-match sdk-ruby Key#value_set). An
    # undef value is rejected — use value_unset to delete (sdk-ruby raises the
    # same ArgumentError). The value is validated/encoded later by the runner via
    # encode_value, so type errors surface there (before any command is buffered).
    method value_set ($value) {
        if (!defined $value) {
            Temporalio::Exception::Argument->throw(message =>
                "value_set on search attribute '$name' requires a value; use "
                . 'value_unset to delete the key');
        }
        return Temporalio::Common::SearchAttributeUpdate->new(
            key => $self, value => $value);
    }

    # value_unset -> a Temporalio::Common::SearchAttributeUpdate that deletes
    # this key (spec section 24; MUST-match sdk-ruby Key#value_unset). The runner
    # encodes an unset as a proper null Payload (no type metadata — the
    # server-side deletion convention).
    method value_unset {
        return Temporalio::Common::SearchAttributeUpdate->new(
            key => $self, is_unset => 1);
    }

    # Encode a value to a temporal.api.common.v1.Payload carrying both the
    # json/plain encoding metadata and the SA "type" metadata. This mirrors
    # sdk-python converter/_search_attributes.py
    # encode_typed_search_attribute_value: default JSON converter +
    # payload.metadata["type"] = <PascalCase type>. Done directly (not via the
    # composite converter) because bare strings would otherwise claim the
    # binary/plain encoding, and bool/keyword-list need normalization.
    method encode_value ($value) {
        my $json_value = $self->_normalize($value);
        my $json       = JSON::PP->new->canonical(1)->allow_blessed(0)
            ->allow_nonref(1)->utf8(1);
        my $data = $json->encode($json_value);
        return Temporalio::Payload->new({
            metadata => { encoding => 'json/plain', type => $metadata_type },
            data     => $data,
        });
    }

    # Helper subs/methods live INSIDE the class block (bare `class` file).
    # Coerce the Perl value into the JSON shape sdk-python would produce.
    method _normalize ($value) {
        if ($metadata_type eq 'Bool') {
            return $value ? JSON::PP::true() : JSON::PP::false();
        }
        if ($metadata_type eq 'KeywordList') {
            unless (ref $value eq 'ARRAY') {
                Temporalio::Exception::Argument->throw(message =>
                    "KeywordList search attribute '$name' requires an arrayref");
            }
            for my $v (@$value) {
                unless (_is_keyword_list_element($v)) {
                    Temporalio::Exception::Argument->throw(message =>
                        "KeywordList search attribute '$name' values must be strings");
                }
            }
            return [ map { "$_" } @$value ];
        }
        return $value;
    }

    # The single "may this value sit in a KeywordList?" predicate. _normalize
    # (encode) and _decode_value_or_skip (wire decode) both call it so the two
    # rules cannot drift apart again: sdk-python's keyword list is all
    # strings, so a number, an undef, a ref, or a blessed object (ref covers
    # the last two) is neither encodable nor decodable as one.
    sub _is_keyword_list_element ($v) {
        return 0 if !defined $v || ref $v;
        return _is_stringish($v) ? 1 : 0;
    }

    sub _is_stringish ($v) {
        # A value is "string-like" if it has the SV string flag set without a
        # pure-number flag. dualvars (e.g. numeric literals) report as numbers.
        my $flags = B::svref_2object(\$v)->FLAGS;
        # POK set, but not IOK/NOK -> a string that isn't also a number.
        return ($flags & B::SVf_POK()) && !($flags & (B::SVf_IOK() | B::SVf_NOK()));
    }

    ADJUST {
        require B;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::SearchAttributeKey - typed search-attribute key

=head1 SYNOPSIS

    use Temporalio::Common::SearchAttributeKey;

    my $key     = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
    my $payload = $key->encode_value('x');   # json/plain "x", metadata type=Keyword

    my $int_key = Temporalio::Common::SearchAttributeKey->int('CustomIntField');
    my $list    = Temporalio::Common::SearchAttributeKey->keyword_list('Tags');

=head1 DESCRIPTION

A typed search-attribute key (spec section 7.4). Create one via a factory
method — C<text>, C<keyword>, C<int>, C<double>, C<bool>, C<datetime>,
C<keyword_list> — each pinning the server index type
(C<indexed_value_type>, a C<temporal.api.enums.v1.IndexedValueType> number)
and the PascalCase C<metadata_type> placed on encoded payloads.

C<encode_value($value)> returns a C<temporal.api.common.v1.Payload> with
C<encoding =E<gt> 'json/plain'> and C<type =E<gt> $metadata_type> metadata,
mirroring sdk-python's typed search-attribute encoding exactly. Booleans
are coerced to JSON C<true>/C<false>; C<keyword_list> requires an arrayref
of strings (any non-string element raises
L<Temporalio::Exception::Argument>). Datetime values are passed through as
the caller's ISO-8601 string — the same form sdk-python emits via
C<datetime.isoformat()>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Common::SearchAttributeKey->new(
        name => ...,
        metadata_type => ...,
        indexed_value_type => ...,
    );

Constructs a Temporalio::Common::SearchAttributeKey. Named parameters:

=over 4

=item C<name>

(required)

=item C<metadata_type>

(required)

=item C<indexed_value_type>

(required)

=back

=head1 METHODS

=head2 bool

Class method constructing a boolean-typed search attribute key with the given name.

=head2 datetime

Class method constructing a datetime-typed search attribute key.

=head2 decode_value

    my $value = $key->decode_value($payload);

The inverse of C<encode_value>: JSON-decodes a C<Payload> produced by C<encode_value>
back into a Perl value (booleans normalize back to C<1>/C<0>). Strict: a payload
this key did not encode (another encoding, malformed data) dies. The wire-decode
path in L<Temporalio::Common::TypedSearchAttributes> skips such a payload
instead; see L<Temporalio::Schedule::Action/Search attributes the SDK cannot type>.

=head2 double

Class method constructing a double-typed search attribute key.

=head2 encode_value

Encodes a Perl value for this key into the proto-typed metadata/data form used in C<SearchAttributes>.

=head2 indexed_value_type

Accessor returning the C<indexed_value_type> value.

=head2 int

Class method constructing an integer-typed search attribute key.

=head2 keyword

Class method constructing a keyword-typed search attribute key.

=head2 keyword_list

Class method constructing a keyword-list-typed search attribute key.

=head2 metadata_type

Accessor returning the C<metadata_type> value.

=head2 name

Accessor returning the C<name> value.

=head2 text

Class method constructing a text-typed search attribute key.

=head2 value_set

    my $update = $key->value_set($value);

Returns a L<Temporalio::Common::SearchAttributeUpdate> setting this key to
C<$value> (spec section 24). An C<undef> value raises
L<Temporalio::Exception::Argument> (use C<value_unset> to delete). The value is
encoded by the runner via C<encode_value> when the update is applied.

=head2 value_unset

    my $update = $key->value_unset;

Returns a L<Temporalio::Common::SearchAttributeUpdate> that deletes this key
(spec section 24). The runner encodes it as a proper null Payload (the
server-side deletion convention).

=cut
