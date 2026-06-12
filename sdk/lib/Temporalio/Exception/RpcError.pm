# ABOUTME: gRPC-layer failure: numeric status code, status name, decoded details.
# ABOUTME: Base class for the specific RpcTimeout/RpcUnauthenticated/etc. subclasses.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::RpcError :isa(Temporalio::Exception) {
    field $status_code :param = undef;
    field $status_name :param = undef;
    field $details :param = undef;

    method status_code            { $status_code }
    method status_name            { $status_name }
    method details                { $details }
}

1;

__END__

=head1 NAME

Temporalio::Exception::RpcError - gRPC-layer failure: numeric status code, status name, decoded details.

=head1 DESCRIPTION

A gRPC-layer failure from a client RPC. C<status_code> is the numeric gRPC status, C<status_name> the gRPC status string (e.g. C<NOT_FOUND>), and C<details> the decoded C<google.rpc.Status> details when present. Specific statuses raise the subclasses L<Temporalio::Exception::RpcTimeout>, L<Temporalio::Exception::RpcUnauthenticated>, L<Temporalio::Exception::RpcPermissionDenied>, and L<Temporalio::Exception::RpcResourceExhausted>. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
