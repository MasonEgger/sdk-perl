# ABOUTME: Raised when a referenced activity does not exist or already completed.
# ABOUTME: Subclass of Temporalio::Exception::NotFound (spec section 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::NotFound;

class Temporalio::Exception::ActivityNotFound :isa(Temporalio::Exception::NotFound) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::ActivityNotFound - Raised when a referenced activity does not exist or already completed.

=head1 DESCRIPTION

Raised when a referenced activity does not exist (or has already completed). See L<Temporalio::Exception::NotFound>. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Exception::ActivityNotFound.

=cut
