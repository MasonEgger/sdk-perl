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

=cut
