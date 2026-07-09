# ABOUTME: Tests encode_common_attributes on Temporalio::Converter::Failure:
# ABOUTME: message/stack_trace relocate into encoded_attributes for the codec
# ABOUTME: chain and are restored on from_failure (spec R75).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Converter::Data;
use Temporalio::Converter::Failure;
use Temporalio::Converter::Payload;
use Temporalio::Exception::Application;
use TestCodec;

my $pc = Temporalio::Converter::Payload->default;

# One exception instance shared across subtests; its stack trace renders
# the same string every to_failure, so a cleartext conversion supplies the
# expected values for the recovery assertions.
my $inner = Temporalio::Exception::Application->new(
    message => 'inner boom',
    type    => 'InnerError',
);
my $exc = Temporalio::Exception::Application->new(
    message => 'outer boom',
    type    => 'OuterError',
    cause   => $inner,
);
my $cleartext = Temporalio::Converter::Failure->default->to_failure($exc, $pc);
my $expected_trace = $cleartext->stack_trace;
T2->ok(length($expected_trace // ''), 'exception rendered a stack trace');

# R75 acceptance: with encode_common_attributes on and a marker codec, the
# on-wire Failure carries the sentinel message, an empty stack trace, and a
# codec-tagged encoded_attributes payload; from_failure recovers the
# originals. Matches sdk-python _failure_converter.py:312-327,461-468.
T2->subtest('on-wire relocation under a marker codec' => sub {
    my $dc = Temporalio::Converter::Data->new(
        failure_converter =>
            Temporalio::Converter::Failure->new(encode_common_attributes => 1),
        payload_codecs => [ TestCodec::Xor->new ],
    );

    my $failure = $dc->to_failure($exc)->get;
    T2->is($failure->message, 'Encoded failure', 'sentinel message on the wire');
    T2->is($failure->stack_trace // '', '', 'stack trace emptied on the wire');
    my $attributes = $failure->encoded_attributes;
    T2->ok(defined $attributes, 'encoded_attributes produced');
    T2->is($attributes->metadata->{encoding}, 'binary/xor-test',
        'encoded_attributes passed through the codec chain');

    # Python encodes every level of the cause chain (to_failure recurses
    # through the public method), so the cause relocates too.
    T2->is($failure->cause->message, 'Encoded failure',
        'cause message relocated too');
    T2->ok(defined $failure->cause->encoded_attributes,
        'cause carries its own encoded_attributes');

    my $back = $dc->from_failure($failure)->get;
    T2->isa_ok($back, 'Temporalio::Exception::Application');
    T2->is($back->message, 'outer boom', 'original message recovered');
    T2->is($back->stack_trace, $expected_trace, 'original stack trace recovered');
    T2->is($back->cause->message, 'inner boom', 'cause message recovered');
});

# from_failure restores encoded attributes regardless of the constructing
# converter's flag (Python's from_failure checks HasField unconditionally,
# _failure_converter.py:312), and without codecs the payload is plain JSON.
T2->subtest('recovery works on a default converter, no codec' => sub {
    my $fc_enc =
        Temporalio::Converter::Failure->new(encode_common_attributes => 1);
    my $failure = $fc_enc->to_failure($exc, $pc);
    T2->is($failure->message, 'Encoded failure',
        'sentinel message without a codec too');
    T2->is($failure->encoded_attributes->metadata->{encoding}, 'json/plain',
        'encoded_attributes is a converter payload pre-codec');

    my $back = Temporalio::Converter::Failure->default
        ->from_failure($failure, $pc);
    T2->is($back->message, 'outer boom',
        'default (flag-off) converter still restores the message');
    T2->is($back->stack_trace, $expected_trace,
        'default converter restores the stack trace');
});

# Flag off: cleartext message/stack_trace, no encoded_attributes.
T2->subtest('flag off leaves attributes cleartext' => sub {
    T2->is($cleartext->message, 'outer boom', 'message stays cleartext');
    T2->is($cleartext->stack_trace, $expected_trace,
        'stack trace stays cleartext');
    T2->ok(!defined $cleartext->encoded_attributes,
        'no encoded_attributes produced');
    T2->ok(!defined $cleartext->cause->encoded_attributes,
        'none on the cause either');
});

T2->done_testing;
