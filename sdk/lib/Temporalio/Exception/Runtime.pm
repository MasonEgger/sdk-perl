# ABOUTME: Exception for Temporalio::Runtime lifecycle errors.
# ABOUTME: Raised on construction failure or use of a shut-down runtime.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Runtime :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::Runtime - runtime lifecycle error

=head1 DESCRIPTION

Raised for L<Temporalio::Runtime> lifecycle errors such as failed C
runtime construction or use after shutdown. See L<Temporalio::Exception>
for the shared fields and behavior.

=cut
