# ABOUTME: Failure wrapping a Nexus operation execution failure (spec section 6.2).
# ABOUTME: Maps to the nexus_operation_execution_failure_info Failure proto variant.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::NexusOperation :isa(Temporalio::Exception) {
    field $scheduled_event_id :param = undef;
    field $endpoint :param = undef;
    field $service :param = undef;
    field $operation :param = undef;
    field $operation_token :param = undef;

    method scheduled_event_id     { $scheduled_event_id }
    method endpoint               { $endpoint }
    method service                { $service }
    method operation              { $operation }
    method operation_token        { $operation_token }
}

1;

__END__

=head1 NAME

Temporalio::Exception::NexusOperation - Failure wrapping a Nexus operation execution failure (spec section 6.2).

=head1 DESCRIPTION

Wraps a Nexus operation execution failure; the underlying error is the C<cause>. Maps to the C<nexus_operation_execution_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
