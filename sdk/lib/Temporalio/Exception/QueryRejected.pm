# ABOUTME: Raised when a workflow query is rejected by reject_condition.
# ABOUTME: status is the workflow execution status string (spec section 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::QueryRejected :isa(Temporalio::Exception) {
    field $status :param = undef;

    method status                 { $status }
}

1;

__END__

=head1 NAME

Temporalio::Exception::QueryRejected - Raised when a workflow query is rejected by reject_condition.

=head1 DESCRIPTION

Raised when a workflow query is rejected by the configured C<reject_condition>. C<status> is the workflow execution status string that triggered the rejection. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::QueryRejected->new(
        status => ...,
    );

Constructs a Temporalio::Exception::QueryRejected. Named parameters:

=over 4

=item C<status>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 status

Accessor returning the C<status> value.

=cut
