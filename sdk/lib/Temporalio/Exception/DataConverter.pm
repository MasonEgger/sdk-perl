# ABOUTME: Exception for payload conversion failures (spec section 6.2).
# ABOUTME: Raised when no converter handles a value or an encoding is unknown.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::DataConverter :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::DataConverter - payload conversion failure

=head1 DESCRIPTION

Raised when payload conversion fails: no registered converter handled a
value, a payload carries an unknown encoding, or serialization itself
failed. See L<Temporalio::Exception> for the shared fields and behavior.

=cut
