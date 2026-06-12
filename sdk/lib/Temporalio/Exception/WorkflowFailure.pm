# ABOUTME: Top-level workflow failure wrapper: the actual failure is the cause.
# ABOUTME: Construction without a cause raises Argument (spec section 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;
use Temporalio::Exception::Argument ();

class Temporalio::Exception::WorkflowFailure :isa(Temporalio::Exception) {
    ADJUST {
        # Spec section 6.2: the cause field is always present — this class is
        # only ever a wrapper around the failure that ended the workflow.
        Temporalio::Exception::Argument->throw(
            message => 'WorkflowFailure requires a cause exception')
            unless defined $self->cause;
    }
}

1;

__END__

=head1 NAME

Temporalio::Exception::WorkflowFailure - top-level workflow failure wrapper

=head1 DESCRIPTION

Raised when a workflow execution fails; the failure that actually ended the
workflow (an application error, cancellation, timeout, ...) is always the
C<cause>. Constructing an instance without a C<cause> raises
L<Temporalio::Exception::Argument>. See L<Temporalio::Exception> for the
shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
