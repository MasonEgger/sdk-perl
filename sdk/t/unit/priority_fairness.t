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
# Construction-time priority_key validation (spec I10, GitHub issue #10).
# Python enforces this in Priority.__post_init__
# (../sdk-python temporalio/common.py:1222-1228): when priority_key is not
# None, it must be an int and must be >= 1.
# ---------------------------------------------------------------------------
T2->subtest('priority_key rejection matrix' => sub {
    for my $bad (0, -1, 2.5, 'high', 'inf', 9**9**9, 'nan', '-inf') {
        my $err = T2->dies(sub {
            Temporalio::Common::Priority->new(priority_key => $bad);
        });
        T2->ok($err, "priority_key => '$bad' throws");
        T2->like($err, qr/priority_key/, "error names priority_key ('$bad')");
        T2->isa_ok($err, 'Temporalio::Exception::Argument');
    }
});

T2->subtest('priority_key accepted values' => sub {
    my $with_key = Temporalio::Common::Priority->new(priority_key => 3);
    T2->is($with_key->priority_key, 3, 'positive integer accepted');

    my $without_key = Temporalio::Common::Priority->new(priority_key => undef);
    T2->is($without_key->priority_key, undef, 'undef accepted');
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
