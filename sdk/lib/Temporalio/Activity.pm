# ABOUTME: Activity-author entry point (spec section 9) — `use Temporalio::Activity;`.
# ABOUTME: Loads the definition base so :isa(Temporalio::Activity::Definition) resolves.
package Temporalio::Activity;

use v5.38;
use warnings;

# A user activity module says `use Temporalio::Activity;` and then declares
# `class My::Activity :isa(Temporalio::Activity::Definition)`. Loading the base
# here means the author does not have to `use` it separately. The activity
# context() functional surface (spec section 9.3) lands in P2.3.
use Temporalio::Activity::Definition ();

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
