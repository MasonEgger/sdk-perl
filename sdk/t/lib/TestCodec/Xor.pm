# ABOUTME: Test-only XOR payload codec: wraps each payload's serialized
# ABOUTME: bytes XORed with a one-byte key under encoding binary/xor-test.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future;
use Temporalio::Converter::PayloadCodec;
use Temporalio::Payload ();

# A real (if silly) codec in the shape spec section 5.4 prescribes for
# encryption-style codecs: encode wraps each payload in a new Payload whose
# data is the original payload's serialized bytes XORed with a one-byte key;
# decode unwraps payloads carrying the wrapper encoding and passes through
# everything else. Returns Futures directly (no `async` sugar) so the codec
# contract — encode/decode resolve to an arrayref — stays the visible API.
class TestCodec::Xor :isa(Temporalio::Converter::PayloadCodec) {
    field $key :param = 0xAB;

    method _xor ($bytes) {
        return '' unless length $bytes;
        return $bytes ^. (chr($key) x length $bytes);
    }

    method encode ($payloads) {
        return Future->done([map {
            Temporalio::Payload->new({
                metadata => { encoding => 'binary/xor-test' },
                data     => $self->_xor($_->encode),
            })
        } @$payloads]);
    }

    method decode ($payloads) {
        return Future->done([map {
            ($_->metadata->{encoding} // '') eq 'binary/xor-test'
                ? Temporalio::Payload->decode($self->_xor($_->data // ''))
                : $_    # pass through payloads we didn't wrap
        } @$payloads]);
    }
}

1;
