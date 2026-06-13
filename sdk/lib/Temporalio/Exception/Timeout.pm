# ABOUTME: Failure indicating a Temporal-enforced timeout fired (spec section 6.2).
# ABOUTME: timeout_type is the Temporal spec string, e.g. start_to_close or heartbeat.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Timeout :isa(Temporalio::Exception) {
    field $timeout_type :param = undef;
    field $last_heartbeat_details :param = undef;

    method timeout_type           { $timeout_type }
    method last_heartbeat_details { $last_heartbeat_details }
}

1;

__END__

=head1 NAME

Temporalio::Exception::Timeout - Failure indicating a Temporal-enforced timeout fired (spec section 6.2).

=head1 DESCRIPTION

Indicates a Temporal-enforced timeout fired. C<timeout_type> is the Temporal spec string form of the TimeoutType enum: C<start_to_close>, C<schedule_to_start>, C<schedule_to_close>, or C<heartbeat>. C<last_heartbeat_details> is an arrayref of decoded payload values from the last recorded heartbeat. Maps to the C<timeout_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::Timeout->new(
        timeout_type => ...,
        last_heartbeat_details => ...,
    );

Constructs a Temporalio::Exception::Timeout. Named parameters:

=over 4

=item C<timeout_type>

(optional, default C<undef>)

=item C<last_heartbeat_details>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 last_heartbeat_details

Accessor returning the C<last_heartbeat_details> value.

=head2 timeout_type

Accessor returning the C<timeout_type> value.

=cut
