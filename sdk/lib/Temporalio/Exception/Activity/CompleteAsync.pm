# ABOUTME: Sentinel exception (spec section 22): thrown by
# ABOUTME: Temporalio::Activity::complete_async to tell the activity dispatcher
# ABOUTME: the activity will complete out of band. The dispatcher catches it
# ABOUTME: and reports ActivityExecutionResult{will_complete_async} to core.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::Activity::CompleteAsync :isa(Temporalio::Exception) {
    # No extra fields: a marker the dispatcher recognizes by class. message is
    # supplied a default so callers can simply `throw` without arguments.
    ADJUST {
        # nothing — message defaulting handled in complete_async / new caller
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Exception::Activity::CompleteAsync - mark an activity for out-of-band completion

=head1 DESCRIPTION

A sentinel exception (spec section 22). An activity body throws it (via
L<Temporalio::Activity/complete_async>) to declare that it will complete B<out
of band> — some external process will later complete, fail, cancel, or
heartbeat the activity through a L<Temporalio::Client::AsyncActivityHandle>.

The activity dispatcher (L<Temporalio::Worker::ActivityDispatcher>) catches
this class specifically and reports
C<ActivityExecutionResult{will_complete_async}> to sdk-core instead of a normal
Completed or Failed outcome. Catching or swallowing C<CompleteAsync> in user
code defeats async completion: the dispatcher only honors it when it propagates
out of the body.

See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and
C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::Activity::CompleteAsync->new(
        message => 'activity will complete asynchronously',
    );

Constructs a Temporalio::Exception::Activity::CompleteAsync. Accepts the shared
L<Temporalio::Exception> parameters.

=cut
