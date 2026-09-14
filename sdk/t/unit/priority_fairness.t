# ABOUTME: Priority fairness_key/fairness_weight proto mapping (spec R81,
# ABOUTME: parity schedule/runtime finding 3): all three fields encode, absent
# ABOUTME: fairness fields stay unset, and a non-numeric weight is rejected.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Temporalio::Common::Priority ();
use Temporalio::Core::Proto ();

Temporalio::Core::Proto->load;

# A scalar that numifies to a valid key (0+ returns 7) but stringifies to
# nonsense ("" returns 'seven'). It satisfies every numeric clause of the
# ADJUST guard, so before spec F14 it constructed cleanly and only died at
# encode with a proto type mismatch rather than Temporalio::Exception::Argument.
package Temporalio::Test::OverloadedNumber {
    use overload
        '0+'     => sub { 7 },
        '""'     => sub { 'seven' },
        fallback => 1;
    sub new ($class) { return bless {}, $class }
}

# ---------------------------------------------------------------------------
# All three fields -> temporal.api.common.v1.Priority
# (Python parity: common.py:1149-1220 _to_proto; proto fields at
# share/proto/temporal/api/common/v1/message.proto:344,354.)
# ---------------------------------------------------------------------------
T2->subtest('to_proto sets priority_key, fairness_key, and fairness_weight' => sub {
    my $pri = Temporalio::Common::Priority->new(
        priority_key    => 1,
        fairness_key    => 'tenant-123',
        fairness_weight => 2.5,
    );
    T2->is($pri->priority_key,    1,            'priority_key reader');
    T2->is($pri->fairness_key,    'tenant-123', 'fairness_key reader');
    T2->is($pri->fairness_weight, 2.5,          'fairness_weight reader');

    my $proto = $pri->to_proto;
    T2->isa_ok($proto, 'Temporalio::Proto::Api::Common::V1::Priority');
    T2->is($proto->priority_key,    1,            'priority_key -> proto');
    T2->is($proto->fairness_key,    'tenant-123', 'fairness_key -> proto');
    T2->is($proto->fairness_weight, 2.5,          'fairness_weight -> proto');
});

# ---------------------------------------------------------------------------
# Absent fairness fields stay unset on the proto (Python sets them only when
# not None; the pure-Perl proto accessors return undef for unset fields).
# ---------------------------------------------------------------------------
T2->subtest('fairness fields left unset when absent' => sub {
    my $pri   = Temporalio::Common::Priority->new(priority_key => 3);
    my $proto = $pri->to_proto;
    T2->is($proto->priority_key, 3, 'priority_key -> proto');
    T2->is($proto->fairness_key,    undef, 'fairness_key unset');
    T2->is($proto->fairness_weight, undef, 'fairness_weight unset');
});

# ---------------------------------------------------------------------------
# Construction-time type validation. Python validates in __post_init__ (its
# fairness_weight enforcement lands via the typed proto setter); the Perl
# equivalent is the constructor guard.
# ---------------------------------------------------------------------------
T2->subtest('non-numeric fairness_weight rejected at construction' => sub {
    my $err = T2->dies(sub {
        Temporalio::Common::Priority->new(fairness_weight => 'heavy');
    });
    T2->like($err, qr/fairness_weight must be a number/,
        'Argument error names the field');
    T2->isa_ok($err, 'Temporalio::Exception::Argument');
});

# ---------------------------------------------------------------------------
# Construction-time priority_key validation (spec I10 and F14, GitHub issue
# #10). Python enforces the lower half in Priority.__post_init__
# (../sdk-python temporalio/common.py:1222-1228): when priority_key is not
# None, it must be an int and must be >= 1. Perl also enforces the upper
# half, because the proto field is int32
# (share/proto/temporal/api/common/v1/message.proto:318): a key above
# 2147483647 can never reach the wire, so the guard rejects it at
# construction with Temporalio::Exception::Argument instead of letting the
# codec raise Protobuf::Exception::Codec::OutOfRange at encode (spec F14).
# ---------------------------------------------------------------------------
T2->subtest('priority_key rejection matrix' => sub {
    for my $bad (0, -1, 2.5, 'high', 'inf', 9**9**9, 'nan', '-inf', 2**31, 3e9) {
        my $err = T2->dies(sub {
            Temporalio::Common::Priority->new(priority_key => $bad);
        });
        T2->ok($err, "priority_key => '$bad' throws");
        T2->like($err, qr/priority_key/, "error names priority_key ('$bad')");
        T2->isa_ok($err, 'Temporalio::Exception::Argument');
    }
});

# ---------------------------------------------------------------------------
# A reference is rejected before any numeric clause runs (spec F14). Overloaded
# numification made the object look like 7 to looks_like_number, int(), and the
# range comparisons, so only an explicit ref test keeps it out.
# ---------------------------------------------------------------------------
T2->subtest('overloaded object rejected at construction' => sub {
    my $err = T2->dies(sub {
        Temporalio::Common::Priority->new(
            priority_key => Temporalio::Test::OverloadedNumber->new);
    });
    T2->ok($err, 'object with overloaded 0+ throws');
    T2->like($err, qr/priority_key/, 'error names priority_key');
    T2->isa_ok($err, 'Temporalio::Exception::Argument');

    my $weight_err = T2->dies(sub {
        Temporalio::Common::Priority->new(
            fairness_weight => Temporalio::Test::OverloadedNumber->new);
    });
    T2->ok($weight_err, 'overloaded fairness_weight throws');
    T2->isa_ok($weight_err, 'Temporalio::Exception::Argument');
});

T2->subtest('priority_key accepted values' => sub {
    my $with_key = Temporalio::Common::Priority->new(priority_key => 3);
    T2->is($with_key->priority_key, 3, 'positive integer accepted');

    my $without_key = Temporalio::Common::Priority->new(priority_key => undef);
    T2->is($without_key->priority_key, undef, 'undef accepted');
});

# ---------------------------------------------------------------------------
# The int32 ceiling itself is a legal key, and the forms the guard accepts
# survive a full encode/decode round trip. Perl's guard is looser than
# Python's isinstance(int): a numeric string, a whitespace-padded string, and
# an exponent form all numify to a whole number and encode cleanly, so pin
# that documented divergence here (spec F14).
# ---------------------------------------------------------------------------
T2->subtest('priority_key int32 ceiling and string forms round-trip' => sub {
    my $Priority = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.Priority');

    my %cases = (
        '2147483647' => 2147483647,   # int32 max, the highest legal key
        '3'          => 3,            # numeric string, unlike Python's int-only
        ' 1'         => 1,            # looks_like_number tolerates padding
        '1e0'        => 1,            # exponent form numifies to a whole number
    );
    for my $input (sort keys %cases) {
        my $pri = Temporalio::Common::Priority->new(priority_key => $input);
        my $round = $Priority->decode($pri->to_proto->encode);
        T2->is($round->priority_key, $cases{$input},
            "priority_key '$input' round-trips as $cases{$input}");
    }
});

# ---------------------------------------------------------------------------
# _from_proto (landed in I4, fe185c0) maps a wire priority_key of 0 (proto3
# default = unset) to undef before construction, so the >= 1 guard above
# must not fire on a decoded proto. Guard the interplay explicitly.
# ---------------------------------------------------------------------------
T2->subtest('_from_proto priority_key 0 decodes to undef without throwing' => sub {
    my $proto = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.Priority')->new({ priority_key => 0 });
    my $pri = Temporalio::Common::Priority->_from_proto($proto);
    T2->is($pri->priority_key, undef, 'wire 0 decodes to undef');
});

T2->subtest('_from_proto priority_key 3 decodes to 3' => sub {
    my $proto = Temporalio::Core::Proto::resolve(
        'temporal.api.common.v1.Priority')->new({ priority_key => 3 });
    my $pri = Temporalio::Common::Priority->_from_proto($proto);
    T2->is($pri->priority_key, 3, 'wire 3 decodes to 3');
});

T2->done_testing;
