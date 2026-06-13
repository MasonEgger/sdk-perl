# ABOUTME: Test-only pass-through payload codec that records each call as
# ABOUTME: "<direction>:<name>" into a shared arrayref (proves chain order).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future;
use Temporalio::Converter::PayloadCodec;

# Records "<direction>:<name>" into the shared arrayref on every call and
# passes payloads through untouched — proves the spec-mandated chain order
# (encode in list order, decode in reverse).
class TestCodec::Recorder :isa(Temporalio::Converter::PayloadCodec) {
    field $name  :param;
    field $calls :param;    # shared arrayref

    method encode ($payloads) {
        push @$calls, "encode:$name";
        return Future->done([@$payloads]);
    }

    method decode ($payloads) {
        push @$calls, "decode:$name";
        return Future->done([@$payloads]);
    }
}

1;
