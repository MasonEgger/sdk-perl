# ABOUTME: Activity-author entry point (spec section 9) — `use Temporalio::Activity;`.
# ABOUTME: Loads the definition base so :isa(Temporalio::Activity::Definition) resolves.
package Temporalio::Activity;

use v5.38;
use warnings;

# A user activity module says `use Temporalio::Activity;` and then declares
# `class My::Activity :isa(Temporalio::Activity::Definition)`. Loading the base
# here means the author does not have to `use` it separately.
use Temporalio::Activity::Definition ();
use Temporalio::Activity::Context ();
use Temporalio::Exception::Activity::CompleteAsync ();
use Temporalio::Exception::Runtime ();

# The activity context() functional surface (spec section 9.3), mirroring the
# reference SDKs' module-level functions (sdk-python activity.info/heartbeat,
# sdk-ruby Activity::Context.current). The current context is the
# dynamically-scoped $Temporalio::Activity::Context::CURRENT, set by the
# dispatcher around the activity body. Calling these outside an activity raises.

# context() -> the current Temporalio::Activity::Context. Raises if not in an
# activity body.
sub context () {
    my $ctx = $Temporalio::Activity::Context::CURRENT;
    Temporalio::Exception::Runtime->throw(
        message => 'not in an activity context')
        unless defined $ctx;
    return $ctx;
}

# info() -> the current activity's info hashref.
sub info () { context()->info }

# heartbeat(@details) -> record a heartbeat on the current activity.
sub heartbeat (@details) { context()->heartbeat(@details) }

# cancellation_details() -> the current activity's
# Temporalio::Activity::CancellationDetails, or undef while it has not been
# cancelled (spec R76; mirrors sdk-python activity.cancellation_details,
# activity.py:315-317).
sub cancellation_details () { context()->cancellation_details }

# is_worker_shutdown() -> bool: true once the worker has begun shutting down
# (spec R84; mirrors sdk-python activity.is_worker_shutdown,
# activity.py:400-409). Distinct from cancellation.
sub is_worker_shutdown () { context()->is_worker_shutdown }

# wait_for_worker_shutdown() -> Future resolving when the worker begins
# shutdown (spec R84; mirrors sdk-python activity.wait_for_worker_shutdown,
# activity.py:412-418).
sub wait_for_worker_shutdown () { context()->wait_for_worker_shutdown }

# complete_async() -> declare the activity will complete out of band (spec
# section 22). Throws Temporalio::Exception::Activity::CompleteAsync; the
# activity dispatcher catches that class specifically and reports
# ActivityExecutionResult{will_complete_async} to core instead of a normal
# Completed/Failed outcome. Unlike context()/info()/heartbeat(), this does NOT
# require an active context — it is a pure sentinel throw (mirrors sdk-python
# activity.raise_complete_async / sdk-ruby Activity.complete_async). Catching it
# in user code defeats async completion.
sub complete_async () {
    Temporalio::Exception::Activity::CompleteAsync->throw(
        message => 'activity will complete asynchronously');
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Activity - entry point for activity authors

=head1 SYNOPSIS

    use feature 'class';
    use Future::AsyncAwait;
    use Temporalio::Activity;

    class My::Activity::SayHello :isa(Temporalio::Activity::Definition) {
        async method run :Defn ($name) {
            return "Hello, $name!";
        }
    }

=head1 DESCRIPTION

C<use Temporalio::Activity;> in an activity module loads
L<Temporalio::Activity::Definition> so the C<:isa> base resolves and the
C<:Defn> attribute handler is in scope. This package also hosts the
activity-context functional surface (C<Temporalio::Activity::context> and
friends, spec section 9.3), documented under L</METHODS>.

=head1 METHODS

=head2 cancellation_details

Returns the current activity's L<Temporalio::Activity::CancellationDetails>
(why it was cancelled: reason plus boolean causes, spec R76), or C<undef>
while the activity has not been cancelled. Dies if called outside an
activity.

=head2 context

Returns the current L<Temporalio::Activity::Context>; dies if called outside an activity.

=head2 complete_async

Declares that the current activity will complete B<out of band> (spec section
22) by throwing L<Temporalio::Exception::Activity::CompleteAsync>. The activity
dispatcher reports C<will_complete_async> to sdk-core; some external process
later completes, fails, cancels, or heartbeats the activity through a
L<Temporalio::Client::AsyncActivityHandle>. Does not require an active activity
context. Catching the thrown exception in the activity body defeats async
completion.

=head2 heartbeat

Records an activity heartbeat with the given details, relaying it through the activity context to sdk-core.

=head2 info

Returns the L<Temporalio::Activity::Info> for the currently executing activity (from the activity context); dies if called outside an activity.

=head2 is_worker_shutdown

True once the worker running this activity has begun shutting down (spec
R84), distinct from cancellation: an ordinary cancel leaves it false. Dies if
called outside an activity.

=head2 wait_for_worker_shutdown

Returns a L<Future> that resolves when the worker begins shutdown (spec R84),
so an activity can react to graceful shutdown independently of its
cancellation token. Dies if called outside an activity.

=cut
