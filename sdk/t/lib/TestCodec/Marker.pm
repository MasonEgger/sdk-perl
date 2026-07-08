# ABOUTME: Test-only marker payload codec for the R7 codec-boundary replay
# ABOUTME: tests: encode wraps under binary/codec-marker; both directions log.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future;
use Temporalio::Converter::PayloadCodec;
use Temporalio::Payload ();

# The marker codec of plan step R7 (finding R6): a wrapping codec in the
# encryption-codec shape of TestCodec::Xor, but whose whole point is the TAG.
# encode wraps every payload it is handed in a new Payload under encoding
# binary/codec-marker (data = the original payload's serialized bytes); decode
# unwraps tagged payloads and passes everything else through. Both directions
# log what they were handed, so a test can assert per-surface coverage:
#
#   - outbound surface covered  -> the completion payload IS tagged;
#   - inbound surface covered   -> the inner payload appears in decoded();
#   - search-attribute excluded -> the SA payload appears in NEITHER
#     encode_seen() nor decode_seen() (the boundary never offers SAs to the
#     codec chain at all, matching sdk-python's skip_search_attributes).
class TestCodec::Marker :isa(Temporalio::Converter::PayloadCodec) {
    field $encode_seen = [];    # every payload handed to encode (originals)
    field $decode_seen = [];    # every payload handed to decode (pre-unwrap)
    field $decoded     = [];    # the inner payloads decode actually unwrapped

    method encode_seen { $encode_seen }
    method decode_seen { $decode_seen }
    method decoded     { $decoded }

    method encode ($payloads) {
        return Future->done([map {
            push @$encode_seen, $_;
            Temporalio::Payload->new({
                metadata => { encoding => 'binary/codec-marker' },
                data     => $_->encode,
            })
        } @$payloads]);
    }

    method decode ($payloads) {
        return Future->done([map {
            push @$decode_seen, $_;
            if (($_->metadata->{encoding} // '') eq 'binary/codec-marker') {
                my $inner = Temporalio::Payload->decode($_->data // '');
                push @$decoded, $inner;
                $inner;
            }
            else {
                $_;    # pass through payloads we didn't wrap
            }
        } @$payloads]);
    }
}

1;
