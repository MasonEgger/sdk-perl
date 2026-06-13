# ABOUTME: Tests Temporalio::Converter::Data (spec section 5.1) and the
# ABOUTME: PayloadCodec chain (spec section 5.4): T-conv-1..4 + failure modes.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Converter::Data;
use Temporalio::Converter::Payload;
use Temporalio::Converter::Failure;
use Temporalio::Exception::Application;
use Temporalio::Exception::DataConverter;
use TestCodec;

# T-conv-1: no codecs, default converters — a hashref round-trips via
# json/plain. The async surface resolves to lists.
T2->subtest('no-codec JSON round-trip of a hashref (T-conv-1)' => sub {
    my $dc = Temporalio::Converter::Data->new;

    my @payloads = $dc->to_payloads([ { a => 1 } ])->get;
    T2->is(scalar @payloads, 1, 'one value in, one payload out');
    T2->is($payloads[0]->metadata->{encoding}, 'json/plain',
        'no codec leaves the converter encoding');
    T2->is($payloads[0]->data, '{"a":1}', 'data is canonical JSON');

    my @values = $dc->from_payloads(\@payloads)->get;
    T2->is(scalar @values, 1, 'one payload in, one value out');
    T2->is($values[0], { a => 1 }, 'hashref round-trips structurally');
});

# T-conv-2: a single XOR codec — payloads leave wrapped in the codec's
# encoding and round-trip back to the original values.
T2->subtest('single XOR codec encode/decode round-trip (T-conv-2)' => sub {
    my $dc = Temporalio::Converter::Data->new(
        payload_codecs => [ TestCodec::Xor->new ],
    );

    my @payloads = $dc->to_payloads([ { a => 1 }, [ 2, 3 ] ])->get;
    T2->is(scalar @payloads, 2, 'two values in, two payloads out');
    T2->is($_->metadata->{encoding}, 'binary/xor-test',
        'payload is codec-wrapped') for @payloads;
    T2->isnt($payloads[0]->data, '{"a":1}', 'data is not the plaintext JSON');

    my @values = $dc->from_payloads(\@payloads)->get;
    T2->is(\@values, [ { a => 1 }, [ 2, 3 ] ], 'values round-trip');
});

# T-conv-3: two codecs A, B — encode applies A then B, decode applies B then
# A (spec-mandated ordering), verified by recorder codecs sharing a log.
T2->subtest('two codecs: encode in order, decode in reverse (T-conv-3)' => sub {
    my @calls;
    my $dc = Temporalio::Converter::Data->new(payload_codecs => [
        TestCodec::Recorder->new(name => 'A', calls => \@calls),
        TestCodec::Recorder->new(name => 'B', calls => \@calls),
    ]);

    my @payloads = $dc->to_payloads([ { a => 1 } ])->get;
    T2->is(\@calls, [ 'encode:A', 'encode:B' ], 'encode runs A then B');

    @calls = ();
    my @values = $dc->from_payloads(\@payloads)->get;
    T2->is(\@calls, [ 'decode:B', 'decode:A' ], 'decode runs B then A');
    T2->is($values[0], { a => 1 }, 'value still round-trips');
});

# T-conv-4: to_failure/from_failure pass the Failure's embedded payloads
# (details, recursively through the cause chain) through the codec chain.
T2->subtest('failure payloads pass through the codec chain (T-conv-4)' => sub {
    my $dc = Temporalio::Converter::Data->new(
        payload_codecs => [ TestCodec::Xor->new ],
    );

    my $inner = Temporalio::Exception::Application->new(
        message => 'inner',
        details => [ { b => 2 } ],
    );
    my $exc = Temporalio::Exception::Application->new(
        message       => 'outer',
        type          => 'X',
        non_retryable => 1,
        details       => [ 'a', 1 ],
        cause         => $inner,
    );

    my $failure = $dc->to_failure($exc)->get;
    T2->is($failure->message, 'outer', 'message stays plaintext');
    T2->is(
        $failure->application_failure_info->details->payloads->[0]
            ->metadata->{encoding},
        'binary/xor-test',
        'details payloads are codec-encoded',
    );
    T2->is(
        $failure->cause->application_failure_info->details->payloads->[0]
            ->metadata->{encoding},
        'binary/xor-test',
        'cause details payloads are codec-encoded too',
    );

    my $back = $dc->from_failure($failure)->get;
    T2->isa_ok($back, 'Temporalio::Exception::Application');
    T2->is($back->message, 'outer', 'message survives');
    T2->is($back->type, 'X', 'type survives');
    T2->is($back->details, [ 'a', 1 ], 'details round-trip through the codec');
    T2->is($back->cause->details, [ { b => 2 } ],
        'cause details round-trip through the codec');
});

# No codecs configured: to_failure is a plain pass-through to the failure
# converter — embedded payloads keep their converter encoding.
T2->subtest('no-codec to_failure leaves payloads unwrapped' => sub {
    my $dc  = Temporalio::Converter::Data->new;
    my $exc = Temporalio::Exception::Application->new(
        message => 'plain',
        details => [ { c => 3 } ],
    );

    my $failure = $dc->to_failure($exc)->get;
    T2->is(
        $failure->application_failure_info->details->payloads->[0]
            ->metadata->{encoding},
        'json/plain',
        'details payloads keep the converter encoding',
    );
    T2->is($dc->from_failure($failure)->get->details, [ { c => 3 } ],
        'round-trips without a codec');
});

# Spec section 5.1 failure modes: a raising codec (and a value no converter
# handles) propagate as Temporalio::Exception::DataConverter.
T2->subtest('codec and converter errors propagate as DataConverter' => sub {
    my $dying = Temporalio::Converter::Data->new(
        payload_codecs => [ TestCodec::Dying->new ],
    );

    my $err = T2->dies(sub { $dying->to_payloads([ { a => 1 } ])->get });
    T2->isa_ok($err, 'Temporalio::Exception::DataConverter');
    T2->like($err->message, qr/dying codec/, 'codec error text preserved');

    my $ok = Temporalio::Converter::Data->new;
    my @payloads = $ok->to_payloads([ { a => 1 } ])->get;
    $err = T2->dies(sub { $dying->from_payloads(\@payloads)->get });
    T2->isa_ok($err, 'Temporalio::Exception::DataConverter');

    # An unhandled value: the payload converter's DataConverter propagates.
    $err = T2->dies(sub { $ok->to_payloads([ qr/regexp/ ])->get });
    T2->isa_ok($err, 'Temporalio::Exception::DataConverter');
});

T2->done_testing;
