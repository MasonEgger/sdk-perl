# ABOUTME: Exception for invalid arguments passed to a Perl-level SDK method.
# ABOUTME: Raised by input validation before any bridge or network work happens.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Argument :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::Argument - invalid argument to an SDK method

=head1 DESCRIPTION

Raised when a caller passes an invalid argument to a Perl-level SDK
method. See L<Temporalio::Exception> for the shared fields and behavior.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Exception::Argument.

=cut
