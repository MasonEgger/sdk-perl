# ABOUTME: Workflow/activity task priority (spec section 7.4), mapping to the
# ABOUTME: temporal.api.common.v1.Priority proto message.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();

use Temporalio::Core::Proto ();
use Temporalio::Exception::Argument ();

class Temporalio::Common::Priority {
    # priority_key: lower number = higher priority. undef leaves it unset
    # (proto default 0 = "use the queue default"). When defined, ADJUST
    # requires a positive integer in int32 range (1 to 2147483647); see the
    # guard below.
    field $priority_key :param = undef;

    # fairness_key/fairness_weight (spec R81, parity schedule/runtime
    # finding 3): the vendored proto carries both
    # (share/proto/temporal/api/common/v1/message.proto:344,354) and Python
    # encodes them when not None (common.py:1149-1220). undef leaves each
    # unset so the server applies its defaults ('' key, weight 1.0).
    field $fairness_key    :param = undef;
    field $fairness_weight :param = undef;

    ADJUST {
        # Construction-time type check, styled after Python's __post_init__
        # priority_key guard (common.py:1222-1228). Python's fairness_weight
        # enforcement happens at _to_proto via the typed proto float setter;
        # Perl's dynamic proto codec would accept garbage, so the guard
        # belongs here. (Spec R81, schedule/runtime finding 3;
        # message.proto:344,354.) The `ref` clause runs first for the same
        # reason it does in the priority_key guard below: an object with
        # overloaded numification satisfies looks_like_number and would
        # otherwise survive construction only to die at encode with a proto
        # type mismatch instead of Temporalio::Exception::Argument (spec F14).
        # No upper bound here, the proto field is a double.
        Temporalio::Exception::Argument->throw(
            message => 'fairness_weight must be a number')
            if defined $fairness_weight
            && (ref $fairness_weight
                || !Scalar::Util::looks_like_number($fairness_weight));

        # priority_key guard (spec I10 and F14, GitHub issue #10), mirroring
        # Python's __post_init__ (common.py:1222-1228): when defined,
        # priority_key must be an integer >= 1. Python's `isinstance(int)`
        # rejects a float like 2.5 outright; the Perl equivalent accepts only
        # values that look_like_number AND are numerically equal to their own
        # int(). The upper bound is Perl's own addition: the proto field is
        # int32 (message.proto:318), so a key above 2147483647 can never
        # reach the wire. Rejecting it here yields
        # Temporalio::Exception::Argument at construction rather than
        # Protobuf::Exception::Codec::OutOfRange at encode; Python needs no
        # such clause because its protobuf raises inside _to_proto.
        #
        # ACCEPTED, which is looser than isinstance(int) and is the
        # documented divergence: a plain integer (3), a numeric string ("3"),
        # whitespace-padded forms (" 1", "1 ", "1\n", "  3  "), an exponent
        # form ("1e0"), an explicit sign ("+1"), and a whole float (1.0,
        # "1.0"). looks_like_number tolerates the padding and the exponent,
        # and each of those numifies to a whole number the codec encodes.
        #
        # REJECTED: any reference, including an object whose overloaded 0+
        # returns a valid key (the `ref` clause runs first, so such an object
        # never reaches the numeric comparisons and can no longer construct
        # and then die at encode with a proto type mismatch); non-numeric
        # strings ("high"); string literals Perl's parser would take but
        # looks_like_number will not ("0x1", "1_000"); the empty string; a
        # dualvar, whose string half is what looks_like_number reads; the
        # magic "0 but true", which numifies to 0 and falls to the `< 1`
        # clause; 0 and negatives; non-whole floats (2.5); and anything above
        # int32 (2**31, 3e9).
        #
        # `$priority_key - $priority_key != 0` is the standard finite check:
        # for any finite number x - x is exactly 0, while Inf - Inf and
        # NaN - NaN both evaluate to NaN, which is != 0. This closes the
        # +Infinity hole ('inf'/'Inf'/'Infinity'/9**9**9 satisfied the
        # int()-equality and >= 1 checks above without it); NaN and -Inf
        # were already rejected by the != int() and < 1 checks respectively.
        # _from_proto (the zero-to-undef map in its priority_key argument)
        # already maps a wire priority_key of 0 to undef before reaching
        # here, so a decoded proto never trips this.
        if (defined $priority_key) {
            Temporalio::Exception::Argument->throw(
                message =>
                    'priority_key must be a positive integer no greater than 2147483647')
                if ref $priority_key
                || !Scalar::Util::looks_like_number($priority_key)
                || $priority_key != int($priority_key)
                || $priority_key - $priority_key != 0
                || $priority_key < 1
                || $priority_key > 2_147_483_647;
        }
    }

    method priority_key    { $priority_key }
    method fairness_key    { $fairness_key }
    method fairness_weight { $fairness_weight }

    method to_proto {
        my $Priority = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.Priority');
        my %args;
        $args{priority_key}    = $priority_key    if defined $priority_key;
        $args{fairness_key}    = $fairness_key    if defined $fairness_key;
        $args{fairness_weight} = $fairness_weight if defined $fairness_weight;
        return $Priority->new(\%args);
    }

    # _from_proto($proto): class method; the inverse of to_proto. MUST-match
    # sdk-python temporalio/common.py Priority._from_proto (~:1203-1210): a
    # proto zero/empty-string scalar decodes back to undef (round-trip parity,
    # spec I4 / GitHub issue #4).
    sub _from_proto ($class, $proto) {
        return $class->new(
            priority_key    => ($proto->priority_key    ? $proto->priority_key    : undef),
            fairness_key    =>
                (defined $proto->fairness_key && length $proto->fairness_key
                    ? $proto->fairness_key : undef),
            fairness_weight => ($proto->fairness_weight ? $proto->fairness_weight : undef),
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Common::Priority - workflow/activity task priority

=head1 SYNOPSIS

    use Temporalio::Common::Priority;

    my $priority = Temporalio::Common::Priority->new(
        priority_key    => 1,
        fairness_key    => 'tenant-123',
        fairness_weight => 2.0,
    );
    my $proto = $priority->to_proto;  # temporal.api.common.v1.Priority

=head1 DESCRIPTION

Task priority passed to C<start_workflow> (spec section 7.4) and to
C<execute_activity>/C<start_activity> (spec R69 / finding A17). A lower
C<priority_key> means higher priority; an undef key leaves the proto field
unset so the server uses the task-queue default. The proto field is an
int32, so a defined key must fall in C<1 .. 2147483647>. C<fairness_key> and
C<fairness_weight> (spec R81) feed the task-queue fairness balancer: each
key gets a virtual queue and tasks dispatch in proportion to the weight
(server clamps weights to [0.001, 1000], default 1.0). Undef leaves either
proto field unset. C<to_proto> builds the
C<temporal.api.common.v1.Priority> message.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Common::Priority->new(
        priority_key    => ...,
        fairness_key    => ...,
        fairness_weight => ...,
    );

Constructs a Temporalio::Common::Priority. Named parameters:

=over 4

=item C<priority_key>

(optional, default C<undef>) When defined, must be a positive integer that
fits the proto's int32 field: C<< >= 1 >> and C<< <= 2147483647 >>. A
non-integer, a sub-1 value, a value above the int32 ceiling, or any
reference raises L<Temporalio::Exception::Argument> at construction, so an
out-of-range key never reaches the codec.

Unlike Python's C<isinstance(int)> check, the Perl guard accepts anything
that looks like a number and equals its own C<int()>. A numeric string
(C<'3'>), a whitespace-padded string (C<' 1'>), an exponent form
(C<'1e0'>), an explicit sign (C<'+1'>), and a whole float (C<1.0>) are all
accepted and encode as the integer they numify to. Non-numeric strings,
C<'0x1'>, C<'1_000'>, the empty string, dualvars, and references are
rejected.

=item C<fairness_key>

(optional, default C<undef>) Short string (max 64 bytes), typically a
tenant id, keying the fairness balancer's virtual queue.

=item C<fairness_weight>

(optional, default C<undef>) Dispatch weight for the fairness key. Must be
a number; a non-numeric value or a reference raises
L<Temporalio::Exception::Argument> at construction.

=back

=head1 METHODS

=head2 priority_key

Accessor returning the C<priority_key> value.

=head2 fairness_key

Accessor returning the C<fairness_key> value.

=head2 fairness_weight

Accessor returning the C<fairness_weight> value.

=head2 to_proto

Builds and returns the C<temporal.api.common.v1.Priority> proto message for this priority.

=cut
