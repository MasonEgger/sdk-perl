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
    # (proto default 0 = "use the queue default").
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
        # message.proto:344,354.)
        Temporalio::Exception::Argument->throw(
            message => 'fairness_weight must be a number')
            if defined $fairness_weight
            && !Scalar::Util::looks_like_number($fairness_weight);
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
unset so the server uses the task-queue default. C<fairness_key> and
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

(optional, default C<undef>)

=item C<fairness_key>

(optional, default C<undef>) Short string (max 64 bytes), typically a
tenant id, keying the fairness balancer's virtual queue.

=item C<fairness_weight>

(optional, default C<undef>) Dispatch weight for the fairness key. Must be
a number; a non-numeric value raises L<Temporalio::Exception::Argument> at
construction.

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
