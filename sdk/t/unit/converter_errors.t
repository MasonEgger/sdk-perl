# ABOUTME: Converter error-path tests (spec R56-R58): failure-conversion
# ABOUTME: wrapping, malformed-UTF-8 rejection, and empty-payload-data behavior.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Converter::Data;
use Temporalio::Converter::Payload::BinaryPlain;
use Temporalio::Converter::Payload::Json;
use Temporalio::Converter::Payload::JsonProtobuf;
use Temporalio::Exception::Application;
use Temporalio::Exception::DataConverter;
use Temporalio::Payload;

# A failure converter whose both directions die with a plain string, to
# prove the Data facade wraps failure conversion the same way it wraps
# payload conversion (finding L22, spec R56).
package Poisoned::FailureConverter {
    sub new          { return bless {}, shift }
    sub to_failure   { die "poisoned to_failure\n" }
    sub from_failure { die "poisoned from_failure\n" }
}

# R56: a raising failure converter surfaces as the typed DataConverter
# exception, exactly like a raising payload converter does.
T2->subtest('poisoned failure converter wraps as DataConverter (R56)' => sub {
    my $poisoned = Temporalio::Converter::Data->new(
        failure_converter => Poisoned::FailureConverter->new,
    );
    my $exc = Temporalio::Exception::Application->new(message => 'boom');

    my $err = T2->dies(sub { $poisoned->to_failure($exc)->get });
    T2->isa_ok($err, 'Temporalio::Exception::DataConverter');
    T2->like($err->message, qr/failure encoding failed: poisoned to_failure/,
        'to_failure error is wrapped with the converter death preserved');

    # Build a real Failure proto with the default converter, then decode it
    # through the poisoned one.
    my $failure = Temporalio::Converter::Data->new->to_failure($exc)->get;
    $err = T2->dies(sub { $poisoned->from_failure($failure)->get });
    T2->isa_ok($err, 'Temporalio::Exception::DataConverter');
    T2->like($err->message,
        qr/failure decoding failed: poisoned from_failure/,
        'from_failure error is wrapped with the converter death preserved');
});

# R57 (finding L23): malformed UTF-8 in json/protobuf payload data raises
# the typed conversion error instead of passing through as latin-1
# mojibake. Adapted from verify-45/pool-payload/probe_cause_mojibake.pl
# (the same probe backs R68): before the fix, bytes FF FE decoded to
# characters U+00FF U+00FE in the materialized message.
T2->subtest('json/protobuf malformed UTF-8 raises, no mojibake (R57)' => sub {
    my $jp = Temporalio::Converter::Payload::JsonProtobuf->new;

    my $bad = qq[{"workflowId":"] . "\xFF\xFE" . qq[bad"}];
    utf8::downgrade($bad);    # payload data is bytes, never characters
    my $payload = Temporalio::Payload->new({
        metadata => {
            encoding    => 'json/protobuf',
            messageType => 'temporal.api.common.v1.WorkflowExecution',
        },
        data => $bad,
    });

    my $err = T2->dies(sub { $jp->from_payload($payload) });
    T2->isa_ok($err, 'Temporalio::Exception::DataConverter');
    T2->like($err->message, qr/UTF-8/,
        'the error names the malformed UTF-8, not a downstream parse');
});

# R58 (finding ADJ1): empty payload data has defined, Python-parity
# behavior on every encoding that used to reach a parser raw.
T2->subtest('empty payload data behaves per Python parity (R58)' => sub {
    # json/plain: sdk-python raises (json.loads(b'') -> RuntimeError
    # "Failed parsing"), so the Perl outcome is the typed error.
    my $json = Temporalio::Converter::Payload::Json->new;
    for my $case ([ 'empty-string data' => '' ], [ 'unset data' => undef ]) {
        my ($label, $data) = @$case;
        my $payload = Temporalio::Payload->new({
            metadata => { encoding => 'json/plain' },
            (defined $data ? (data => $data) : ()),
        });
        my $err = T2->dies(sub { $json->from_payload($payload) });
        T2->isa_ok($err, 'Temporalio::Exception::DataConverter');
        T2->like($err->message, qr/empty data/,
            "json/plain $label raises the typed error deliberately");
    }

    # json/protobuf: sdk-python wraps the ParseError as a typed error; the
    # Perl converter must not leak the raw Protobuf::JSON death.
    my $jp = Temporalio::Converter::Payload::JsonProtobuf->new;
    my $proto_payload = Temporalio::Payload->new({
        metadata => {
            encoding    => 'json/protobuf',
            messageType => 'temporal.api.common.v1.WorkflowExecution',
        },
        data => '',
    });
    my $err = T2->dies(sub { $jp->from_payload($proto_payload) });
    T2->isa_ok($err, 'Temporalio::Exception::DataConverter');
    T2->unlike(ref($err), qr/^Protobuf::/,
        'the raw parser exception does not escape');

    # binary/plain: sdk-python returns the empty bytes, so Perl returns the
    # empty string, defined and without dying.
    my $bp = Temporalio::Converter::Payload::BinaryPlain->new;
    my $bp_payload = Temporalio::Payload->new({
        metadata => { encoding => 'binary/plain' },
        data     => '',
    });
    my $bytes;
    T2->ok(T2->lives(sub { $bytes = $bp->from_payload($bp_payload) }),
        'binary/plain empty data does not die');
    T2->is($bytes, '', 'binary/plain empty data maps to the empty string');
});

T2->done_testing;
