# ABOUTME: Raised when the bridge reports a problem recording an activity heartbeat.
# ABOUTME: Spec section 6.2; thrown from the heartbeat() activity-context call.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Heartbeat :isa(Temporalio::Exception) {
}

1;

__END__

=head1 NAME

Temporalio::Exception::Heartbeat - Raised when the bridge reports a problem recording an activity heartbeat.

=head1 DESCRIPTION

Raised from the activity context C<heartbeat()> call when the bridge reports a problem recording the heartbeat. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Exception::Heartbeat.

=cut
