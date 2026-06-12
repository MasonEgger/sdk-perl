# ABOUTME: Raised when a referenced Temporal namespace does not exist.
# ABOUTME: Subclass of Temporalio::Exception::NotFound (spec section 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::NotFound;

class Temporalio::Exception::NamespaceNotFound :isa(Temporalio::Exception::NotFound) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::NamespaceNotFound - Raised when a referenced Temporal namespace does not exist.

=head1 DESCRIPTION

Raised when a referenced Temporal namespace does not exist. See L<Temporalio::Exception::NotFound>. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
