# ABOUTME: Raised when a workflow update is rejected or fails (spec section 19):
# ABOUTME: the decoded validator/handler failure is always the cause.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::WorkflowUpdateFailed :isa(Temporalio::Exception) {
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Exception::WorkflowUpdateFailed - a workflow update was rejected or failed

=head1 DESCRIPTION

Raised by C<< $handle->execute_update >> / C<< $update_handle->result >> when a
workflow update outcome is a failure (spec section 19). The actual failure that
the validator or handler produced is the C<cause> (decoded from the update
C<Outcome.failure>). See L<Temporalio::Exception> for the shared C<message>,
C<stack_trace>, and C<cause> fields.

This single class covers both a validator rejection and a post-acceptance
handler failure: the server reports both as an update C<Outcome.failure>, and
the client cannot (and need not) distinguish them.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Exception::WorkflowUpdateFailed.

=cut
