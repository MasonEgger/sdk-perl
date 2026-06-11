# ABOUTME: Exception for low-level FFI/bridge errors from the sdk-core C ABI.
# ABOUTME: Constructed from bridge failure byte arrays in async completions.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Bridge :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::Bridge - low-level FFI/bridge error

=head1 DESCRIPTION

Raised when the sdk-core C bridge reports a failure, typically decoded
from a bridge failure byte array in an async completion. See
L<Temporalio::Exception> for the shared fields and behavior.

=cut
