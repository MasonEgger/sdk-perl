# ABOUTME: Failure wrapping an activity execution failure (spec section 6.2).
# ABOUTME: retry_state is the lowercased Temporal RetryState enum suffix string.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Activity :isa(Temporalio::Exception) {
    field $activity_id :param = undef;
    field $activity_type :param = undef;
    field $attempt :param = undef;
    field $identity :param = undef;
    field $retry_state :param = undef;
    field $started_event_id :param = undef;
    field $scheduled_event_id :param = undef;

    method activity_id            { $activity_id }
    method activity_type          { $activity_type }
    method attempt                { $attempt }
    method identity               { $identity }
    method retry_state            { $retry_state }
    method started_event_id       { $started_event_id }
    method scheduled_event_id     { $scheduled_event_id }
}

1;

__END__

=head1 NAME

Temporalio::Exception::Activity - Failure wrapping an activity execution failure (spec section 6.2).

=head1 DESCRIPTION

Wraps an activity execution failure; the underlying activity error is the C<cause>. C<retry_state> is the lowercased suffix of the Temporal RetryState enum (e.g. C<in_progress>, C<non_retryable_failure>). Maps to the C<activity_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::Activity->new(
        activity_id => ...,
        activity_type => ...,
        attempt => ...,
        identity => ...,
        retry_state => ...,
        started_event_id => ...,
        scheduled_event_id => ...,
    );

Constructs a Temporalio::Exception::Activity. Named parameters:

=over 4

=item C<activity_id>

(optional, default C<undef>)

=item C<activity_type>

(optional, default C<undef>)

=item C<attempt>

(optional, default C<undef>)

=item C<identity>

(optional, default C<undef>)

=item C<retry_state>

(optional, default C<undef>)

=item C<started_event_id>

(optional, default C<undef>)

=item C<scheduled_event_id>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 activity_id

Accessor returning the C<activity_id> value.

=head2 activity_type

Accessor returning the C<activity_type> value.

=head2 attempt

Accessor returning the C<attempt> value.

=head2 identity

Accessor returning the C<identity> value.

=head2 retry_state

Accessor returning the C<retry_state> value.

=head2 scheduled_event_id

Accessor returning the C<scheduled_event_id> value.

=head2 started_event_id

Accessor returning the C<started_event_id> value.

=cut
