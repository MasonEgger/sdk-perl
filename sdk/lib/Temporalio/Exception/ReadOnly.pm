# ABOUTME: Exception raised when workflow code attempts a state-mutating or
# ABOUTME: command-emitting operation from a read-only context (a :Query handler
# ABOUTME: or an update validator). The sdk-python ReadOnlyContextError analog.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::ReadOnly :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::ReadOnly - illegal action in a read-only workflow context

=head1 DESCRIPTION

Raised when workflow code attempts a command-emitting or state-mutating
operation while the runner is executing a read-only block: a C<:Query>
handler or an update validator (spec section 19.2, step R24). This is the
analog of sdk-python's C<ReadOnlyContextError>. From a query handler the
error surfaces as a failed query response; from an update validator it is
routed as a workflow task failure. See L<Temporalio::Exception> for the
shared fields and behavior.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Exception::ReadOnly.

=cut
