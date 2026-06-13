# ABOUTME: Test-only payload codec that always fails — drives the spec
# ABOUTME: section 5.1 failure mode (codec errors surface as DataConverter).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future;
use Temporalio::Converter::PayloadCodec;

class TestCodec::Dying :isa(Temporalio::Converter::PayloadCodec) {
    method encode ($payloads) {
        return Future->fail("dying codec: encode refused\n");
    }

    method decode ($payloads) {
        return Future->fail("dying codec: decode refused\n");
    }
}

1;
