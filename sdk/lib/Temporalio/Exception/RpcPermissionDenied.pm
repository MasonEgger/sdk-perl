# ABOUTME: gRPC permission-denied failure; subclass of RpcError (spec section 6.2).
# ABOUTME: Raised when the caller lacks permission for the requested operation.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::RpcError;

class Temporalio::Exception::RpcPermissionDenied :isa(Temporalio::Exception::RpcError) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::RpcPermissionDenied - gRPC permission-denied failure; subclass of RpcError (spec section 6.2).

=head1 DESCRIPTION

Raised for the gRPC C<PERMISSION_DENIED> status. See L<Temporalio::Exception::RpcError> for the shared fields. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
