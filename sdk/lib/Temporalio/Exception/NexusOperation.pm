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

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::NexusOperation->new(
        scheduled_event_id => ...,
        endpoint => ...,
        service => ...,
        operation => ...,
        operation_token => ...,
    );

Constructs a Temporalio::Exception::NexusOperation. Named parameters:

=over 4

=item C<scheduled_event_id>

(optional, default C<undef>)

=item C<endpoint>

(optional, default C<undef>)

=item C<service>

(optional, default C<undef>)

=item C<operation>

(optional, default C<undef>)

=item C<operation_token>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 endpoint

Accessor returning the C<endpoint> value.

=head2 operation

Accessor returning the C<operation> value.

=head2 operation_token

Accessor returning the C<operation_token> value.

=head2 scheduled_event_id

Accessor returning the C<scheduled_event_id> value.

=head2 service

Accessor returning the C<service> value.

=cut
