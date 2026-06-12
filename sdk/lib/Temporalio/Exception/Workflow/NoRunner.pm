# ABOUTME: Raised when a Temporalio::Workflow::* function runs outside a workflow.
# ABOUTME: Workflow context functions require the deterministic runner (spec 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Workflow::NoRunner :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::Workflow::NoRunner - Raised when a Temporalio::Workflow::* function runs outside a workflow.

=head1 DESCRIPTION

Raised when a C<Temporalio::Workflow::*> context function is called outside a workflow body — the deterministic workflow runner is not active. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
