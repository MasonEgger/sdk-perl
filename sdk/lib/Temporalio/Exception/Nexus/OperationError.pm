# ABOUTME: Handler-raised Nexus OperationError (spec section 26.4): an operation
# ABOUTME: that failed or was cancelled (not infra) -> failure-carrying StartOperationResponse.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

# Raised by a Nexus operation handler to signal that the OPERATION itself failed
# or was cancelled (as opposed to a handler/infra error, which becomes a
# HandlerError). The dispatcher converts an OperationError into a
# failure-carrying StartOperationResponse (spec section 26.4): state 'failed' ->
# Application failure, state 'canceled' -> Cancelled failure. $state is one of
# 'failed' or 'canceled' (the nexusrpc operation states); the wrapped error is
# the `cause`.
class Temporalio::Exception::Nexus::OperationError :isa(Temporalio::Exception) {
    field $state :param = 'failed';

    method state { $state }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Exception::Nexus::OperationError - a Nexus operation that failed or was cancelled

=head1 DESCRIPTION

Raised by a Nexus operation handler to signal that the operation itself failed
or was cancelled (spec section 26.4). The dispatcher produces a
failure-carrying C<StartOperationResponse>: C<state> C<'failed'> maps to an
Application failure, C<'canceled'> to a Cancelled failure. The underlying error
is the C<cause>. See L<Temporalio::Exception> for the shared C<message>,
C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    Temporalio::Exception::Nexus::OperationError->new(
        message => ..., state => 'failed'|'canceled', cause => ...);

=over 4

=item C<state>

(optional, default C<'failed'>) one of C<'failed'> or C<'canceled'>.

=back

=head1 METHODS

=head2 state

Accessor returning the operation state (C<'failed'> or C<'canceled'>).

=cut
