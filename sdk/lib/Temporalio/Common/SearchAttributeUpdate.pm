# ABOUTME: A single typed search-attribute update (spec section 24) — a (key,
# ABOUTME: value) set or an unset, produced by SearchAttributeKey value_set /
# ABOUTME: value_unset and consumed by Temporalio::Workflow::upsert_search_attributes.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

class Temporalio::Common::SearchAttributeUpdate {
    # The Temporalio::Common::SearchAttributeKey this update applies to.
    field $key :param;

    # The value to set; ignored (and undef) when this is an unset. The runner
    # converts it: a set encodes via $key->encode_value, an unset writes a
    # proper null Payload (the deletion convention — spec section 24.2).
    field $value :param = undef;

    # True for an unset (value_unset); false for a set (value_set). A separate
    # flag rather than "value is undef" so a set whose value happens to be undef
    # would still be a set (value_set rejects undef up front, mirroring sdk-ruby).
    field $is_unset :param = 0;

    method key      { return $key }
    method value    { return $value }
    method is_unset { return $is_unset ? 1 : 0 }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::SearchAttributeUpdate - a typed search-attribute update

=head1 SYNOPSIS

    use Temporalio::Common::SearchAttributeKey;

    my $key = Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField');
    my $set   = $key->value_set('x');   # a SearchAttributeUpdate (set)
    my $unset = $key->value_unset;      # a SearchAttributeUpdate (unset)

    Temporalio::Workflow::upsert_search_attributes($set, $unset);

=head1 DESCRIPTION

A single typed search-attribute update (spec section 24). Produced by
L<Temporalio::Common::SearchAttributeKey>'s C<value_set> / C<value_unset> and
passed to C<Temporalio::Workflow::upsert_search_attributes>. The update carries
the C<key>, the C<value> (for a set), and an C<is_unset> flag; the runner owns
the payload conversion (a set encodes the value with the key's typed metadata;
an unset writes a proper null Payload, the server-side deletion convention).

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Common::SearchAttributeUpdate->new(
        key      => $key,
        value    => $value,   # optional, undef for an unset
        is_unset => 0,        # optional, 1 for an unset
    );

Constructs a Temporalio::Common::SearchAttributeUpdate. Most callers use the
C<value_set> / C<value_unset> factory methods on
L<Temporalio::Common::SearchAttributeKey> rather than this constructor.

=head1 METHODS

=head2 key

Returns the L<Temporalio::Common::SearchAttributeKey> this update applies to.

=head2 value

Returns the value to set (C<undef> for an unset).

=head2 is_unset

Returns true when this update unsets (deletes) the key.

=cut
