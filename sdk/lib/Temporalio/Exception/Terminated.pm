# ABOUTME: Failure indicating a workflow execution was terminated (spec section 6.2).
# ABOUTME: Maps to the terminated_failure_info Failure proto variant.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Terminated :isa(Temporalio::Exception) {
    field $reason :param = undef;

    method reason                 { $reason }
}

1;

__END__

=head1 NAME

Temporalio::Exception::Terminated - Failure indicating a workflow execution was terminated (spec section 6.2).

=head1 DESCRIPTION

Indicates a workflow execution was terminated. C<reason> carries the termination reason when known. Maps to the C<terminated_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::Terminated->new(
        reason => ...,
    );

Constructs a Temporalio::Exception::Terminated. Named parameters:

=over 4

=item C<reason>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 reason

Accessor returning the C<reason> value.

=cut
