# ABOUTME: Failure originating inside the Temporal server (spec section 6.2).
# ABOUTME: Maps to the server_failure_info Failure proto variant.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Server :isa(Temporalio::Exception) {
    field $non_retryable :param = 0;
    field $details :param = undef;

    method non_retryable          { $non_retryable }
    method details                { $details }
}

1;

__END__

=head1 NAME

Temporalio::Exception::Server - Failure originating inside the Temporal server (spec section 6.2).

=head1 DESCRIPTION

Indicates a failure originating inside the Temporal server itself. Maps to the C<server_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
