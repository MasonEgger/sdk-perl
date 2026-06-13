# ABOUTME: Typed search-attribute key (spec section 7.4) — the MUST-match
# ABOUTME: SearchAttributeKey type system and its payload (metadata.type)
# ABOUTME: encoding, mirroring sdk-python temporalio/common.py + converter.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use JSON::PP ();
use Scalar::Util ();
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
                if (ref $v || !defined $v
                    || Scalar::Util::blessed($v)) {
                    Temporalio::Exception::Argument->throw(message =>
                        "KeywordList search attribute '$name' values must be strings");
                }
                # Reject non-string scalars (numbers) to match the
                # all-strings invariant of sdk-python's keyword list.
                unless (_is_stringish($v)) {
                    Temporalio::Exception::Argument->throw(message =>
                        "KeywordList search attribute '$name' values must be strings");
                }
            }
            return [ map { "$_" } @$value ];
        }
        return $value;
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

=cut
