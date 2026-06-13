# ABOUTME: Failure recorded when a workflow execution is reset (spec section 6.2).
# ABOUTME: Maps to the reset_workflow_failure_info Failure proto variant.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::ResetWorkflow :isa(Temporalio::Exception) {
    field $last_heartbeat_details :param = undef;

    method last_heartbeat_details { $last_heartbeat_details }
}

1;

__END__

=head1 NAME

Temporalio::Exception::ResetWorkflow - Failure recorded when a workflow execution is reset (spec section 6.2).

=head1 DESCRIPTION

Recorded when a workflow execution is reset. C<last_heartbeat_details> is an arrayref of decoded payload values. Maps to the C<reset_workflow_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::ResetWorkflow->new(
        last_heartbeat_details => ...,
    );

Constructs a Temporalio::Exception::ResetWorkflow. Named parameters:

=over 4

=item C<last_heartbeat_details>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 last_heartbeat_details

Accessor returning the C<last_heartbeat_details> value.

=cut
