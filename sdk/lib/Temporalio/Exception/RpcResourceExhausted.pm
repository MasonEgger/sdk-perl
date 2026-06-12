# ABOUTME: gRPC resource-exhausted failure; subclass of RpcError (spec section 6.2).
# ABOUTME: Raised when the server reports rate limiting or quota exhaustion.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::RpcError;

class Temporalio::Exception::RpcResourceExhausted :isa(Temporalio::Exception::RpcError) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::RpcResourceExhausted - gRPC resource-exhausted failure; subclass of RpcError (spec section 6.2).

=head1 DESCRIPTION

Raised for the gRPC C<RESOURCE_EXHAUSTED> status. See L<Temporalio::Exception::RpcError> for the shared fields. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
