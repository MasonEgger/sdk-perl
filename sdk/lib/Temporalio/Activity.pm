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

1;

__END__

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
C<:Defn> attribute handler is in scope. The activity-context functional
surface (C<Temporalio::Activity::context>, etc. — spec section 9.3) is added
in a later phase.

=cut
