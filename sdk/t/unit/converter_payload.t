# ABOUTME: Tests Temporalio::Converter::Payload (spec section 5.2): the default
# ABOUTME: composite, all five encodings (T-pay-1..5), and custom-converter order.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use feature 'class';
no warnings 'experimental::class';

use JSON::PP ();
use Scalar::Util qw(blessed);

use Temporalio::Core::Proto;
use Temporalio::Payload;
use Temporalio::Payload::RawBytes;
use Temporalio::Payload::BinaryProto;
use Temporalio::Converter::Payload;
use Temporalio::Converter::Payload::Json;
use Temporalio::Exception::DataConverter;

my $PAYLOAD_CLASS =
    Temporalio::Core::Proto::resolve('temporal.api.common.v1.Payload');
my $EXEC_CLASS =
    Temporalio::Core::Proto::resolve('temporal.api.common.v1.WorkflowExecution');

my $pc = Temporalio::Converter::Payload->default;

# T-pay-1: undef -> binary/null -> undef.
T2->subtest('undef round-trips via binary/null (T-pay-1)' => sub {
    my $payload = $pc->to_payload(undef);
    T2->isa_ok($payload, $PAYLOAD_CLASS);
    T2->is($payload->metadata->{encoding}, 'binary/null', 'encoding is binary/null');
    T2->ok(!length($payload->data // ''), 'data is empty');
    T2->is($pc->from_payload($payload), undef, 'round-trips back to undef');
});

# T-pay-2: plain hashref -> json/plain (canonical JSON::PP) -> same hashref.
T2->subtest('hashref round-trips via json/plain (T-pay-2)' => sub {
    my $payload = $pc->to_payload({ a => 1 });
    T2->is($payload->metadata->{encoding}, 'json/plain', 'encoding is json/plain');
    T2->is($payload->data, '{"a":1}', 'data is canonical JSON');
    T2->is($pc->from_payload($payload), { a => 1 }, 'round-trips structurally');

    my $nested = { b => [1, 2, { c => 'x' }], a => 1 };
    T2->is(
        $pc->to_payload($nested)->data,
        '{"a":1,"b":[1,2,{"c":"x"}]}',
        'canonical mode sorts keys deterministically',
    );
    T2->is(
        $pc->from_payload($pc->to_payload($nested)),
        $nested,
        'nested structure round-trips',
    );
});

# T-pay-3: generated proto message -> json/protobuf with messageType metadata.
T2->subtest('proto message round-trips via json/protobuf (T-pay-3)' => sub {
    my $msg = $EXEC_CLASS->new({ workflow_id => 'wf-1', run_id => 'run-1' });

    my $payload = $pc->to_payload($msg);
    T2->is($payload->metadata->{encoding}, 'json/protobuf', 'encoding is json/protobuf');
    T2->is(
        $payload->metadata->{messageType},
        'temporal.api.common.v1.WorkflowExecution',
        'messageType metadata carries the full proto type name',
    );
    T2->ok(length($payload->data), 'data holds the JSON form');

    my $got = $pc->from_payload($payload);
    T2->isa_ok($got, $EXEC_CLASS);
    T2->is($got->workflow_id, 'wf-1',  'workflow_id survives');
    T2->is($got->run_id,      'run-1', 'run_id survives');
});

# BinaryProto-hinted message -> binary/protobuf round-trip.
T2->subtest('BinaryProto hint selects binary/protobuf' => sub {
    my $msg  = $EXEC_CLASS->new({ workflow_id => 'wf-2', run_id => 'run-2' });
    my $hint = Temporalio::Payload::BinaryProto->new(message => $msg);

    my $payload = $pc->to_payload($hint);
    T2->is($payload->metadata->{encoding}, 'binary/protobuf', 'encoding is binary/protobuf');
    T2->is(
        $payload->metadata->{messageType},
        'temporal.api.common.v1.WorkflowExecution',
        'messageType metadata carries the full proto type name',
    );
    T2->is($payload->data, $msg->encode, 'data is the proto wire form');

    my $got = $pc->from_payload($payload);
    T2->isa_ok($got, $EXEC_CLASS);
    T2->is($got->workflow_id, 'wf-2',  'workflow_id survives');
    T2->is($got->run_id,      'run-2', 'run_id survives');
});

# binary/plain is claimed ONLY by the explicit RawBytes wrapper. A bare scalar
# is treated as text and encodes json/plain (matching sdk-python/sdk-ruby and
# keeping strings interoperable + readable in tooling). Wrap bytes to opt in.
T2->subtest('RawBytes -> binary/plain; bare strings -> json/plain' => sub {
    my $raw = "\x00\x01\xfe\xff";

    my $wrapped = $pc->to_payload(Temporalio::Payload::RawBytes->new(bytes => $raw));
    T2->is($wrapped->metadata->{encoding}, 'binary/plain', 'RawBytes hint maps to binary/plain');
    T2->is($wrapped->data, $raw, 'hinted bytes stored verbatim');
    T2->is($pc->from_payload($wrapped), $raw, 'hinted bytes round-trip');

    # The common case: a bare string is text, so it goes json/plain, not binary.
    my $sp = $pc->to_payload('Hello, Mason!');
    T2->is($sp->metadata->{encoding}, 'json/plain', 'a bare string encodes json/plain');
    T2->is($sp->data, '"Hello, Mason!"', 'json/plain data is the JSON-quoted string');
    T2->is($pc->from_payload($sp), 'Hello, Mason!', 'the string round-trips');
});

# T-pay-4: unhandled blessed object raises DataConverter naming the class.
T2->subtest('unhandled blessed object raises DataConverter (T-pay-4)' => sub {
    my $obj = bless {}, 'Some::Unhandled::Class';
    my $ok  = eval { $pc->to_payload($obj); 1 };
    T2->ok(!$ok, 'to_payload dies for an unhandled blessed object');
    T2->isa_ok($@, 'Temporalio::Exception::DataConverter');
    T2->like($@->message, qr/Some::Unhandled::Class/, 'diagnostic names the class');

    my $unknown = Temporalio::Payload->new({
        metadata => { encoding => 'no/such-encoding' },
    });
    $ok = eval { $pc->from_payload($unknown); 1 };
    T2->ok(!$ok, 'from_payload dies for an unknown encoding');
    T2->isa_ok($@, 'Temporalio::Exception::DataConverter');
    T2->like($@->message, qr{no/such-encoding}, 'diagnostic names the encoding');
});

# T-pay-5: a custom subclass registered first wins over the defaults.
class Local::Test::CustomConverter :isa(Temporalio::Converter::Payload) {
    method encoding { 'test/custom' }

    method to_payload ($value) {
        return undef unless ref $value eq 'HASH';
        return Temporalio::Payload->new({
            metadata => { encoding => $self->encoding },
            data     => JSON::PP->new->canonical->utf8->encode($value),
        });
    }

    method from_payload ($payload, $type_hint = undef) {
        return JSON::PP->new->utf8->decode($payload->data);
    }
}

T2->subtest('custom subclass registered first wins (T-pay-5)' => sub {
    my $composite = Temporalio::Converter::Payload->new(converters => [
        Local::Test::CustomConverter->new,
        Temporalio::Converter::Payload::Json->new,
    ]);

    my $payload = $composite->to_payload({ a => 1 });
    T2->is(
        $payload->metadata->{encoding},
        'test/custom',
        'first-registered converter claims the value before Json',
    );
    T2->is($composite->from_payload($payload), { a => 1 },
        'dispatch routes test/custom back to the custom converter');

    T2->is(
        $composite->to_payload([2, 3])->metadata->{encoding},
        'json/plain',
        'values the custom converter declines fall through to Json',
    );
});

T2->done_testing;
