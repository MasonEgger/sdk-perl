# ABOUTME: Author test (spec R59, finding L24): the BinaryPlain and Json
# ABOUTME: POD claim conditions must map to the actual claiming code.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();

my $lib = "$FindBin::Bin/../lib/Temporalio/Converter/Payload";

sub slurp ($path) {
    open my $fh, '<:encoding(UTF-8)', $path or die "open $path: $!";
    local $/;
    return readline $fh;
}

# BinaryPlain: the claiming code (to_payload) accepts ONLY RawBytes-wrapped
# values; bare scalars, flagged or not, fall through to json/plain. The POD
# must say exactly that and must not resurrect the pre-settlement claim that
# unflagged plain strings are bytes.
T2->subtest('BinaryPlain POD matches its claiming code (R59)' => sub {
    my $src = slurp("$lib/BinaryPlain.pm");
    my ($pod) = $src =~ /^__END__$(.*)\z/ms;
    T2->ok(defined $pod, 'BinaryPlain has a POD section');

    T2->unlike($pod, qr/without the internal UTF-8 flag/,
        'stale unflagged-string-is-bytes claim is gone');
    T2->like($pod, qr/RawBytes/,
        'POD names the RawBytes wrapper as the claim condition');
    T2->like($pod, qr/only/i,
        'POD states the claim is exclusive to the wrapper');

    # And the claim it describes really is the code's claim: to_payload
    # gates on the RawBytes isa-check and nothing else.
    T2->like($src, qr/isa\('Temporalio::Payload::RawBytes'\)/,
        'claiming code gates on the RawBytes isa-check');
});

# Json: the catch-all claims every plain non-reference scalar (strings with
# or without the UTF-8 flag, numbers); BinaryPlain never competes for bare
# scalars. The POD must not route unflagged strings to BinaryPlain.
T2->subtest('Json POD matches its claiming code (R59)' => sub {
    my $src = slurp("$lib/Json.pm");
    my ($pod) = $src =~ /^__END__$(.*)\z/ms;
    T2->ok(defined $pod, 'Json has a POD section');

    T2->unlike($pod, qr/unflagged strings are claimed by/,
        'stale BinaryPlain-claims-unflagged-strings routing is gone');
    T2->like($pod, qr/RawBytes/,
        'POD points bytes callers at the RawBytes wrapper instead');
});

T2->done_testing;
