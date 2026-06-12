# ABOUTME: Failure raised by a Nexus handler (spec section 6.2).
# ABOUTME: Maps to the nexus_handler_failure_info Failure proto variant.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::NexusHandler :isa(Temporalio::Exception) {
    field $type :param = undef;
    field $retry_behavior :param = undef;

    method type                   { $type }
    method retry_behavior         { $retry_behavior }
}

1;

__END__

=head1 NAME

Temporalio::Exception::NexusHandler - Failure raised by a Nexus handler (spec section 6.2).

=head1 DESCRIPTION

Raised when a Nexus handler fails. C<type> is the Nexus spec error type string (e.g. C<BAD_REQUEST>); C<retry_behavior> is the raw NexusHandlerErrorRetryBehavior enum value. Maps to the C<nexus_handler_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
