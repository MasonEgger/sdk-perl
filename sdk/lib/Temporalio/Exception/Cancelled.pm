# ABOUTME: Failure indicating a workflow, activity, or operation was cancelled.
# ABOUTME: Maps to the canceled_failure_info Failure proto variant (spec section 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Cancelled :isa(Temporalio::Exception) {
    field $details :param = undef;

    method details                { $details }
}

1;

__END__

=head1 NAME

Temporalio::Exception::Cancelled - Failure indicating a workflow, activity, or operation was cancelled.

=head1 DESCRIPTION

Indicates cancellation of a workflow, activity, or other operation. Maps to the C<canceled_failure_info> variant of the Temporal Failure proto. C<details> is an arrayref of decoded payload values. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::Cancelled->new(
        details => ...,
    );

Constructs a Temporalio::Exception::Cancelled. Named parameters:

=over 4

=item C<details>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 details

Accessor returning the C<details> value.

=cut
