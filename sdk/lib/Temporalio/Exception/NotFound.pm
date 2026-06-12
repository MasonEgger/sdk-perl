# ABOUTME: Base not-found failure (spec section 6.2); see the specific subclasses.
# ABOUTME: WorkflowNotFound, ActivityNotFound, and NamespaceNotFound inherit from this.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::NotFound :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::NotFound - Base not-found failure (spec section 6.2); see the specific subclasses.

=head1 DESCRIPTION

Base class for not-found failures. The specific subclasses are L<Temporalio::Exception::WorkflowNotFound>, L<Temporalio::Exception::ActivityNotFound>, and L<Temporalio::Exception::NamespaceNotFound>. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
