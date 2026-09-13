# ABOUTME: Retry policy for workflows/activities (spec section 7.4) — MUST-match
# ABOUTME: sdk-python defaults, mapping to temporal.api.common.v1.RetryPolicy.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::Proto ();

class Temporalio::Common::RetryPolicy {
    # Defaults MUST match sdk-python temporalio/common.py RetryPolicy:
    # initial_interval 1s, backoff 2.0, maximum_interval None, attempts 0
    # (unlimited), non_retryable_error_types None. Durations are seconds
    # Perl-side; to_proto converts to google.protobuf.Duration.
    field $initial_interval          :param = 1;
    field $backoff_coefficient       :param = 2.0;
    field $maximum_interval          :param = undef;
    field $maximum_attempts          :param = 0;
    field $non_retryable_error_types :param = undef;

    # Explicit readers: field :reader needs perl 5.40+; floor is 5.38.
    method initial_interval          { $initial_interval }
    method backoff_coefficient       { $backoff_coefficient }
    method maximum_interval          { $maximum_interval }
    method maximum_attempts          { $maximum_attempts }
    method non_retryable_error_types { $non_retryable_error_types }

    # Build the temporal.api.common.v1.RetryPolicy proto message. Seconds are
    # split into a google.protobuf.Duration (seconds + nanos). An undef
    # maximum_interval is omitted (the server then derives it from
    # initial_interval).
    method to_proto {
        my $RetryPolicy = Temporalio::Core::Proto::resolve(
            'temporal.api.common.v1.RetryPolicy');

        my %args = (
            initial_interval    => Temporalio::Core::Proto::duration_from_seconds(
                $initial_interval),
            backoff_coefficient => $backoff_coefficient,
            maximum_attempts    => $maximum_attempts,
        );
        $args{maximum_interval} =
            Temporalio::Core::Proto::duration_from_seconds($maximum_interval)
            if defined $maximum_interval;
        $args{non_retryable_error_types} = [ @$non_retryable_error_types ]
            if $non_retryable_error_types && @$non_retryable_error_types;

        return $RetryPolicy->new(\%args);
    }

    # _from_proto($proto): class method; the inverse of to_proto. MUST-match
    # sdk-python temporalio/common.py RetryPolicy.from_proto (~:63-75): an
    # unset maximum_interval decodes to undef, an empty
    # non_retryable_error_types decodes to undef (round-trip parity, spec I4 /
    # GitHub issue #4).
    sub _from_proto ($class, $proto) {
        my $maximum_interval = $proto->maximum_interval;
        my $errors           = $proto->non_retryable_error_types;
        return $class->new(
            initial_interval    =>
                Temporalio::Core::Proto::seconds_from_duration(
                    $proto->initial_interval),
            backoff_coefficient => $proto->backoff_coefficient,
            maximum_interval    =>
                (defined $maximum_interval
                    ? Temporalio::Core::Proto::seconds_from_duration(
                        $maximum_interval)
                    : undef),
            maximum_attempts    => $proto->maximum_attempts,
            non_retryable_error_types =>
                ($errors && @$errors ? [ @$errors ] : undef),
        );
    }

    # The seconds<->google.protobuf.Duration conversion pair lives in
    # Temporalio::Core::Proto (I14; formerly local _duration/
    # _duration_to_seconds helpers here).
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Common::RetryPolicy - retry policy for workflows and activities

=head1 SYNOPSIS

    use Temporalio::Common::RetryPolicy;

    my $policy = Temporalio::Common::RetryPolicy->new(
        initial_interval          => 1,        # seconds (defaults shown)
        backoff_coefficient       => 2.0,
        maximum_interval          => 100,      # seconds; undef = server default
        maximum_attempts          => 0,        # 0 = unlimited
        non_retryable_error_types => [ 'BadInput' ],
    );

    my $proto = $policy->to_proto;   # temporal.api.common.v1.RetryPolicy

=head1 DESCRIPTION

The retry policy passed to C<start_workflow> and activity options (spec
section 7.4). Durations are seconds Perl-side; C<to_proto> builds the
C<temporal.api.common.v1.RetryPolicy> message, converting each interval to
a C<google.protobuf.Duration>. An undef C<maximum_interval> is omitted so
the server derives it. The field defaults MUST match the reference SDKs
(verified against sdk-python F<temporalio/common.py>): C<initial_interval>
1s, C<backoff_coefficient> 2.0, C<maximum_interval> undef,
C<maximum_attempts> 0 (unlimited), C<non_retryable_error_types> none.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Common::RetryPolicy->new(
        initial_interval => ...,
        backoff_coefficient => ...,
        maximum_interval => ...,
        maximum_attempts => ...,
        non_retryable_error_types => ...,
    );

Constructs a Temporalio::Common::RetryPolicy. Named parameters:

=over 4

=item C<initial_interval>

(optional, default C<1>)

=item C<backoff_coefficient>

(optional, default C<2.0>)

=item C<maximum_interval>

(optional, default C<undef>)

=item C<maximum_attempts>

(optional, default C<0>)

=item C<non_retryable_error_types>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 backoff_coefficient

Accessor returning the C<backoff_coefficient> value.

=head2 initial_interval

Accessor returning the C<initial_interval> value.

=head2 maximum_attempts

Accessor returning the C<maximum_attempts> value.

=head2 maximum_interval

Accessor returning the C<maximum_interval> value.

=head2 non_retryable_error_types

Accessor returning the C<non_retryable_error_types> value.

=head2 to_proto

Builds and returns the C<temporal.api.common.v1.RetryPolicy> proto message; second-valued intervals are split into C<google.protobuf.Duration> seconds and nanos.

=cut
