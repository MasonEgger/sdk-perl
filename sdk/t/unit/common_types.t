# ABOUTME: Unit tests for the spec section 7.4 common types — RetryPolicy and
# ABOUTME: Priority proto mapping, plus the MUST-match TypedSearchAttributes /
# ABOUTME: SearchAttributeKey payload encoding (metadata.type) and untyped guard.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use JSON::PP ();
use Temporalio::Common::RetryPolicy ();
use Temporalio::Common::Priority ();
use Temporalio::Common::SearchAttributeKey ();
use Temporalio::Common::TypedSearchAttributes ();
use Temporalio::Core::Proto ();

Temporalio::Core::Proto->load;

# ---------------------------------------------------------------------------
# RetryPolicy -> temporal.api.common.v1.RetryPolicy
# ---------------------------------------------------------------------------
T2->subtest('RetryPolicy maps to the proto message' => sub {
    my $rp = Temporalio::Common::RetryPolicy->new(
        initial_interval          => 1,
        backoff_coefficient       => 2.0,
        maximum_interval          => 100,
        maximum_attempts          => 5,
        non_retryable_error_types => ['BadInput'],
    );

    my $proto = $rp->to_proto;
    T2->isa_ok($proto, 'Temporalio::Proto::Api::Common::V1::RetryPolicy');

    T2->is($proto->initial_interval->seconds, 1,
        'initial_interval seconds -> Duration');
    T2->is($proto->initial_interval->nanos, 0, 'initial_interval nanos zero');
    T2->is($proto->maximum_interval->seconds, 100,
        'maximum_interval -> Duration');
    T2->is($proto->backoff_coefficient, 2.0, 'backoff_coefficient passthrough');
    T2->is($proto->maximum_attempts, 5, 'maximum_attempts passthrough');
    T2->is($proto->non_retryable_error_types, ['BadInput'],
        'non_retryable_error_types repeated');

    my $class = ref $proto;
    my $back  = $class->decode($proto->encode);
    T2->is($back->maximum_attempts, 5, 'survives encode/decode');
});

T2->subtest('RetryPolicy defaults MUST match sdk-python' => sub {
    # initial_interval 1s, backoff 2.0, maximum_interval None, attempts 0,
    # non_retryable None.
    my $rp = Temporalio::Common::RetryPolicy->new;
    T2->is($rp->initial_interval, 1, 'default initial_interval 1s');
    T2->is($rp->backoff_coefficient, 2.0, 'default backoff 2.0');
    T2->is($rp->maximum_interval, undef, 'default maximum_interval undef');
    T2->is($rp->maximum_attempts, 0, 'default maximum_attempts 0');

    my $proto = $rp->to_proto;
    T2->ok(!defined $proto->maximum_interval,
        'unset maximum_interval omitted from proto');
    T2->is($proto->non_retryable_error_types, [],
        'no non_retryable_error_types when unset');
});

T2->subtest('RetryPolicy fractional intervals split into nanos' => sub {
    my $rp = Temporalio::Common::RetryPolicy->new(initial_interval => 1.5);
    my $d  = $rp->to_proto->initial_interval;
    T2->is($d->seconds, 1, 'fractional seconds floor');
    T2->is($d->nanos, 500_000_000, 'fractional nanos');
});

# ---------------------------------------------------------------------------
# Priority -> temporal.api.common.v1.Priority
# ---------------------------------------------------------------------------
T2->subtest('Priority maps to the proto message' => sub {
    my $pri = Temporalio::Common::Priority->new(priority_key => 3);
    T2->is($pri->priority_key, 3, 'priority_key reader');
    my $proto = $pri->to_proto;
    T2->isa_ok($proto, 'Temporalio::Proto::Api::Common::V1::Priority');
    T2->is($proto->priority_key, 3, 'priority_key -> proto');
});

# ---------------------------------------------------------------------------
# SearchAttributeKey factories + payload encoding (MUST match metadata.type)
# ---------------------------------------------------------------------------
my %CASE = (
    keyword      => { name => 'CustomKeywordField', value => 'x',
                      type => 'Keyword',     data => '"x"' },
    text         => { name => 'CustomTextField',    value => 'hello world',
                      type => 'Text',        data => '"hello world"' },
    int          => { name => 'CustomIntField',     value => 42,
                      type => 'Int',         data => '42' },
    double       => { name => 'CustomDoubleField',  value => 3.5,
                      type => 'Double',      data => '3.5' },
    datetime     => { name => 'CustomDatetimeField',
                      value => '2026-06-12T20:00:00Z',
                      type => 'Datetime',    data => '"2026-06-12T20:00:00Z"' },
    keyword_list => { name => 'CustomKeywordListField',
                      value => [ 'a', 'b' ],
                      type => 'KeywordList', data => '["a","b"]' },
);

T2->subtest('SearchAttributeKey factories encode typed payloads' => sub {
    for my $factory (sort keys %CASE) {
        my $c   = $CASE{$factory};
        my $key = Temporalio::Common::SearchAttributeKey->$factory($c->{name});
        T2->is($key->name, $c->{name}, "$factory key name");
        T2->is($key->metadata_type, $c->{type}, "$factory metadata_type");

        my $payload = $key->encode_value($c->{value});
        T2->is($payload->metadata->{type}, $c->{type},
            "$factory payload metadata.type = $c->{type}");
        T2->is($payload->metadata->{encoding}, 'json/plain',
            "$factory payload encoding json/plain");
        T2->is($payload->data, $c->{data}, "$factory payload data");
    }
});

T2->subtest('bool search attribute encodes JSON true/false' => sub {
    my $key = Temporalio::Common::SearchAttributeKey->bool('CustomBoolField');
    T2->is($key->metadata_type, 'Bool', 'bool metadata_type');

    my $t = $key->encode_value(JSON::PP::true());
    T2->is($t->data, 'true', 'JSON::PP true -> true');
    T2->is($t->metadata->{type}, 'Bool', 'bool type metadata');

    my $f = $key->encode_value(JSON::PP::false());
    T2->is($f->data, 'false', 'JSON::PP false -> false');

    T2->is($key->encode_value(1)->data, 'true',  'perl-true -> true');
    T2->is($key->encode_value(0)->data, 'false', 'perl-false -> false');
});

T2->subtest('IndexedValueType numbers MUST match the proto enum' => sub {
    T2->is(Temporalio::Common::SearchAttributeKey->text('a')->indexed_value_type,
        1, 'TEXT = 1');
    T2->is(
        Temporalio::Common::SearchAttributeKey->keyword('a')->indexed_value_type,
        2, 'KEYWORD = 2');
    T2->is(Temporalio::Common::SearchAttributeKey->int('a')->indexed_value_type,
        3, 'INT = 3');
    T2->is(
        Temporalio::Common::SearchAttributeKey->double('a')->indexed_value_type,
        4, 'DOUBLE = 4');
    T2->is(Temporalio::Common::SearchAttributeKey->bool('a')->indexed_value_type,
        5, 'BOOL = 5');
    T2->is(
        Temporalio::Common::SearchAttributeKey->datetime('a')->indexed_value_type,
        6, 'DATETIME = 6');
    T2->is(
        Temporalio::Common::SearchAttributeKey->keyword_list('a')
            ->indexed_value_type,
        7, 'KEYWORD_LIST = 7');
});

T2->subtest('keyword_list rejects non-string elements' => sub {
    my $key = Temporalio::Common::SearchAttributeKey->keyword_list('K');
    my $err = T2->dies(sub { $key->encode_value([ 'ok', 42 ]) });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'non-string keyword-list element raises Argument')
        or T2->diag('got: ' . (ref($err) || $err // 'no exception'));
});

# ---------------------------------------------------------------------------
# TypedSearchAttributes -> SearchAttributes proto map
# ---------------------------------------------------------------------------
T2->subtest('TypedSearchAttributes encode into the proto map' => sub {
    my $tsa = Temporalio::Common::TypedSearchAttributes->new([
        [ Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField')
            => 'x' ],
        [ Temporalio::Common::SearchAttributeKey->int('CustomIntField') => 42 ],
    ]);

    my $proto = $tsa->to_proto;
    T2->isa_ok($proto, 'Temporalio::Proto::Api::Common::V1::SearchAttributes');

    my $fields = $proto->indexed_fields;
    T2->is([ sort keys %$fields ],
        [ 'CustomIntField', 'CustomKeywordField' ],
        'both keys land in indexed_fields map');

    T2->is($fields->{CustomKeywordField}->metadata->{type}, 'Keyword',
        'keyword pair metadata.type');
    T2->is($fields->{CustomKeywordField}->data, '"x"', 'keyword pair data');
    T2->is($fields->{CustomIntField}->metadata->{type}, 'Int',
        'int pair metadata.type');
    T2->is($fields->{CustomIntField}->data, '42', 'int pair data');

    my $class = ref $proto;
    my $back  = $class->decode($proto->encode);
    T2->is($back->indexed_fields->{CustomIntField}->data, '42',
        'survives encode/decode');
});

T2->subtest('empty TypedSearchAttributes -> empty map' => sub {
    my $tsa   = Temporalio::Common::TypedSearchAttributes->new([]);
    my $proto = $tsa->to_proto;
    T2->is([ keys %{ $proto->indexed_fields } ], [], 'empty -> empty map');
});

T2->subtest('untyped input raises Argument (no type guessing)' => sub {
    # spec section 7.4: a bare untyped hashref is rejected.
    my $err = T2->dies(sub {
        Temporalio::Common::TypedSearchAttributes->new(
            { CustomKeywordField => 'x' });
    });
    T2->ok($err && $err->isa('Temporalio::Exception::Argument'),
        'bare hashref to constructor raises Argument')
        or T2->diag('got: ' . (ref($err) || $err // 'no exception'));

    # A pair whose key is a bare string (not a SearchAttributeKey).
    my $err2 = T2->dies(sub {
        Temporalio::Common::TypedSearchAttributes->new(
            [ [ 'CustomKeywordField' => 'x' ] ]);
    });
    T2->ok($err2 && $err2->isa('Temporalio::Exception::Argument'),
        'non-key pair element raises Argument')
        or T2->diag('got: ' . (ref($err2) || $err2 // 'no exception'));
});

T2->done_testing;
