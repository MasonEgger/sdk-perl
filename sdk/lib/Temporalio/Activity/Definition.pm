# ABOUTME: Base class for class-based activity definitions (spec sections 9.1, 8.5).
# ABOUTME: Hosts the :Defn attribute handler and the per-class _activity_defs registry.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Activity::Attributes ();

# The four constraints in spec section 10.1 (proven in t/spike/) apply here:
#   1. This base MUST be declared with `class`, not `package`.
#   2. The :Defn handler MUST live in the inheritance chain (this class).
#   3. The handler MUST use :ATTR(CODE,BEGIN) — workers `require` user
#      activity modules at runtime, after the global CHECK pass.
#   4. $data arrives as ARRAYREF or undef, never a bare string.
class Temporalio::Activity::Definition {
    use Attribute::Handlers;

    # Per-class registry: package name => { activity_type => { code => $ref,
    # no_thread_cancellation => 0|1 } }.
    our %_DEFS;

    sub Defn :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;

        # The decorated method's own name. A method named "run" defaults its
        # activity type to the class basename (spec section 9.1); any other
        # method defaults to the method name.
        my $method_name = *{$sym}{NAME};

        my ($name, %opts) =
            Temporalio::Activity::Attributes::parse_defn($data, $method_name, $pkg);

        $_DEFS{$pkg}{$name} = {
            code                   => $ref,
            no_thread_cancellation => $opts{no_thread_cancellation} // 0,
            sync                   => $opts{sync} // 0,
        };
        return;
    }

    # Class method: the activity definitions registered on this class (and only
    # this class — :Defn is declared per concrete activity class).
    sub _activity_defs ($class) {
        return $_DEFS{$class} // {};
    }
}

1;

__END__

=head1 NAME

Temporalio::Activity::Definition - base class for class-based activities

=head1 SYNOPSIS

    package My::Activity::SayHello;
    use feature 'class';
    use Future::AsyncAwait;
    use Temporalio::Activity;

    class My::Activity::SayHello :isa(Temporalio::Activity::Definition) {
        async method run :Defn ($name) {
            return "Hello, $name!";
        }
    }

    my $defs = My::Activity::SayHello->_activity_defs;
    # { SayHello => { code => $methodref, no_thread_cancellation => 0 } }

=head1 DESCRIPTION

Activity classes inherit this base and decorate their activity methods with
the C<:Defn> attribute (spec section 9.1). Registration happens at the
subclass's compile time via L<Attribute::Handlers> (C<:ATTR(CODE,BEGIN)>),
which is the correct phase for an SDK whose users register activities by
C<require>-ing modules at worker startup.

=head2 The C<:Defn> attribute

=over 4

=item C<:Defn>

Activity type = the method name, or the class basename when the method is
named C<run>.

=item C<:Defn('CustomType')>

Explicit activity type name.

=item C<:Defn(name=CustomType,no_thread_cancellation=1)>

Keyword form.

=back

=head2 C<_activity_defs>

Class method returning the per-class hash of activity type name to
C<< { code => $methodref, no_thread_cancellation => 0|1 } >>.

=cut
