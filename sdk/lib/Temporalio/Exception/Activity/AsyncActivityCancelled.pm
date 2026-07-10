# ABOUTME: Raised by AsyncActivityHandle->heartbeat (spec section 22) when the
# ABOUTME: heartbeat response signals cancel_requested / activity_paused /
# ABOUTME: activity_reset — the only cancellation-delivery channel to an
# ABOUTME: out-of-band activity. Double-L Cancelled, matching the base class.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Cancelled;

class Temporalio::Exception::Activity::AsyncActivityCancelled
    :isa(Temporalio::Exception::Cancelled)
{
    # The three response flags that triggered the cancellation, each a boolean.
    field $cancel_requested :param = 0;
    field $activity_paused  :param = 0;
    field $activity_reset   :param = 0;

    method cancel_requested { $cancel_requested }
    method activity_paused  { $activity_paused }
    method activity_reset   { $activity_reset }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Exception::Activity::AsyncActivityCancelled - heartbeat reported the activity should stop

=head1 DESCRIPTION

Raised by L<Temporalio::Client::AsyncActivityHandle/heartbeat> (spec section
22) when the heartbeat response sets C<cancel_requested>, C<activity_paused>,
and/or C<activity_reset>. For an out-of-band (async) activity, a heartbeat is
the only channel through which the server delivers a cancellation request, a
pause, or a reset, so the SDK surfaces it as a raised exception rather than a
return value.

A subclass of L<Temporalio::Exception::Cancelled> (double-L C<Cancelled>,
matching that class), so existing cancellation-aware code that catches
C<Temporalio::Exception::Cancelled> also catches this. The three boolean
accessors report which flags were set.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::Activity::AsyncActivityCancelled->new(
        message          => 'activity cancellation requested',
        cancel_requested => 1,
        activity_paused  => 0,
        activity_reset   => 0,
        details          => ...,    # inherited from Cancelled
    );

Constructs the exception. C<cancel_requested>/C<activity_paused>/
C<activity_reset> each default to 0; C<details> is inherited from
L<Temporalio::Exception::Cancelled>.

=head1 METHODS

=head2 cancel_requested

True when the server asked the activity to cancel itself.

=head2 activity_paused

True when the activity is paused.

=head2 activity_reset

True when the activity was reset (current run only).

=cut
