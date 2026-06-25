# ABOUTME: Base class for class-based workflow definitions (spec sections 8.6, 10.1).
# ABOUTME: Hosts the :Run/:Signal/:Query/:Update/:UpdateValidator/:Init handlers and the per-class registry.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Workflow::Attributes ();
use Temporalio::Exception::Argument ();

# The four constraints in spec section 10.1 (proven in t/spike/) apply here:
#   1. This base MUST be declared with `class`, not `package`.
#   2. The attribute handlers MUST live in the inheritance chain (this class).
#   3. The handlers MUST use :ATTR(CODE,BEGIN) — workers `require` user
#      workflow modules at runtime, after the global CHECK pass.
#   4. $data arrives as ARRAYREF or undef, never a bare string.
class Temporalio::Workflow::Definition {
    use Attribute::Handlers;

    # Per-class registry keyed by package name:
    #   { run        => $methodref,
    #     run_type   => 'WorkflowType',   # resolved workflow type name
    #     signals    => { name => $methodref },
    #     queries    => { name => $methodref },
    #     updates    => { name => $methodref },
    #     validators => { update_name => $methodref },
    #     init       => $methodref,
    #     dynamic    => { signal => $mref, query => $mref, update => $mref } }
    our %_DEFS;

    # :Run — exactly one per class (spec section 10.1). A second :Run raises
    # Temporalio::Exception::Argument at the subclass's compile time.
    sub Run :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my $method_name = *{$sym}{NAME};

        if (exists $_DEFS{$pkg}{run}) {
            Temporalio::Exception::Argument->throw(
                message => "Multiple :Run methods found on $pkg",
            );
        }
        my $type = Temporalio::Workflow::Attributes::parse_run($data, $method_name, $pkg);
        $_DEFS{$pkg}{run}      = $ref;
        $_DEFS{$pkg}{run_type} = $type;
        return;
    }

    sub Signal :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        _register_handler($pkg, *{$sym}{NAME}, $ref, $data, 'Signal', 'signals');
        return;
    }

    sub Query :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        _register_handler($pkg, *{$sym}{NAME}, $ref, $data, 'Query', 'queries');
        return;
    }

    sub Update :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        _register_handler($pkg, *{$sym}{NAME}, $ref, $data, 'Update', 'updates');
        return;
    }

    # :UpdateValidator('updateName') — pairs a synchronous validator with an
    # :Update handler (spec section 10.1; mirrors sdk-ruby
    # workflow_update_validator). The argument names the update method/handler.
    sub UpdateValidator :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my @items = ref($data) eq 'ARRAY' ? @$data : ();
        my $update_name = $items[0];
        if (!defined $update_name || !length $update_name) {
            Temporalio::Exception::Argument->throw(
                message => ":UpdateValidator requires the update name it validates",
            );
        }
        if (exists $_DEFS{$pkg}{validators}{$update_name}) {
            Temporalio::Exception::Argument->throw(
                message => "Multiple update validators found for $update_name on $pkg",
            );
        }
        $_DEFS{$pkg}{validators}{$update_name} = $ref;
        return;
    }

    # default_versioning_behavior string -> proto VersioningBehavior enum
    # value (verified against the proto descriptor + sdk-ruby common_enums.rb):
    # unspecified=0, pinned=1, auto_upgrade=2.
    my %_VERSIONING_BEHAVIOR = (
        unspecified  => 0,
        pinned       => 1,
        auto_upgrade => 2,
    );

    # :VersioningBehavior('pinned') — declares the per-workflow versioning
    # behavior (spec §29.1), reported to core in the activation completion. The
    # attribute may sit on any method of the class (conventionally :Run); it
    # registers per-package, so a second one or an unknown token raises at the
    # subclass's compile time.
    sub VersioningBehavior :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my @items = ref($data) eq 'ARRAY' ? @$data : ();
        my $behavior = $items[0];
        if (!defined $behavior || !exists $_VERSIONING_BEHAVIOR{$behavior}) {
            Temporalio::Exception::Argument->throw(
                message => ":VersioningBehavior requires one of "
                    . join(', ', sort keys %_VERSIONING_BEHAVIOR)
                    . (defined $behavior ? " (got '$behavior')" : ''),
            );
        }
        if (exists $_DEFS{$pkg}{versioning_behavior}) {
            Temporalio::Exception::Argument->throw(
                message => "Multiple :VersioningBehavior attributes found on $pkg",
            );
        }
        $_DEFS{$pkg}{versioning_behavior} = $behavior;
        return;
    }

    # :Init — the constructor hook that runs in workflow context just before
    # :Run (spec section 10.1; mirrors Python's workflow.init).
    sub Init :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        if (exists $_DEFS{$pkg}{init}) {
            Temporalio::Exception::Argument->throw(
                message => "Multiple :Init methods found on $pkg",
            );
        }
        $_DEFS{$pkg}{init} = $ref;
        return;
    }

    # Register a :Signal/:Query/:Update handler under its resolved name,
    # rejecting a duplicate within the same kind (spec: two handlers of the
    # same kind sharing a name is invalid; sdk-python "Multiple signal methods
    # found for <name>"). Dynamic handlers land in the per-kind dynamic slot.
    # File-scope sub inside the class block so it is visible from the handlers.
    sub _register_handler ($pkg, $method_name, $ref, $data, $kind, $bucket) {
        my ($name, %opts) =
            Temporalio::Workflow::Attributes::parse_handler($data, $method_name, $kind);

        if ($opts{dynamic}) {
            my $dyn_kind = lc $kind;
            if (exists $_DEFS{$pkg}{dynamic}{$dyn_kind}) {
                Temporalio::Exception::Argument->throw(
                    message => "Multiple dynamic $kind handlers found on $pkg",
                );
            }
            $_DEFS{$pkg}{dynamic}{$dyn_kind} = $ref;
            return;
        }

        if (exists $_DEFS{$pkg}{$bucket}{$name}) {
            Temporalio::Exception::Argument->throw(
                message => "Multiple $kind methods found for $name on $pkg",
            );
        }
        $_DEFS{$pkg}{$bucket}{$name} = $ref;
        return;
    }

    # Class method: the workflow definitions registered on this class. Returns
    # a normalised hash with all buckets present (possibly empty).
    sub _workflow_defs ($class) {
        my $d = $_DEFS{$class} // {};
        return {
            run        => $d->{run},
            run_type   => $d->{run_type},
            signals    => $d->{signals}    // {},
            queries    => $d->{queries}    // {},
            updates    => $d->{updates}    // {},
            validators => $d->{validators} // {},
            init       => $d->{init},
            dynamic    => $d->{dynamic}    // {},
        };
    }

    # Class method: the workflow type name for this class (spec section 8.6).
    # undef when the class has no :Run method.
    sub _workflow_type ($class) {
        return ($_DEFS{$class} // {})->{run_type};
    }

    # Class method: the per-workflow versioning behavior string (spec §29.1),
    # 'unspecified' when no :VersioningBehavior attribute is present.
    sub _versioning_behavior ($class) {
        return ($_DEFS{$class} // {})->{versioning_behavior} // 'unspecified';
    }

    # Class method: the proto VersioningBehavior enum value (0/1/2) for this
    # class's behavior — what core expects in the activation completion.
    sub _versioning_behavior_value ($class) {
        return $_VERSIONING_BEHAVIOR{ $class->_versioning_behavior };
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::Definition - base class for class-based workflows

=head1 SYNOPSIS

    package My::Workflow::Greeting;
    use feature 'class';
    use Future::AsyncAwait;
    use Temporalio::Workflow;

    class My::Workflow::Greeting :isa(Temporalio::Workflow::Definition) {
        field $greeting = 'Hello';

        async method run :Run ($name) {
            return "$greeting, $name!";
        }

        method change_greeting :Signal('changeGreeting') ($new) {
            $greeting = $new;
        }

        method current_greeting :Query ($) { return $greeting }
    }

=head1 DESCRIPTION

Workflow classes inherit this base and decorate their methods with the
C<:Run>, C<:Signal>, C<:Query>, C<:Update>, C<:UpdateValidator>, and C<:Init>
attributes (spec section 10.1). Registration happens at the subclass's compile
time via L<Attribute::Handlers> (C<:ATTR(CODE,BEGIN)>) — the correct phase for
an SDK whose users register workflows by C<require>-ing modules at worker
startup.

=head2 Attributes

=over 4

=item C<:Run> / C<:Run('CustomType')>

The single workflow entry point — exactly one per class. A second C<:Run>
raises L<Temporalio::Exception::Argument>. The workflow type defaults to the
class basename when the method is named C<run>, the method name otherwise, or
an explicit override.

=item C<:Signal> / C<:Query> / C<:Update>

Handler name defaults to the method name; C<:Signal('foo')> or
C<:Signal(name=foo)> overrides; C<:Signal(dynamic=1)> registers a catch-all
dynamic handler (which must not carry a name). A duplicate name within a kind
raises L<Temporalio::Exception::Argument>.

=item C<:UpdateValidator('updateName')>

Pairs a synchronous validator with the named C<:Update> handler.

=item C<:Init>

The constructor hook that runs just before C<:Run>.

=back

=head2 Class methods

=over 4

=item C<_workflow_defs>

The normalised per-class definition hash (C<run>, C<run_type>, C<signals>,
C<queries>, C<updates>, C<validators>, C<init>, C<dynamic>).

=item C<_workflow_type>

The resolved workflow type name (C<undef> if the class has no C<:Run>).

=back

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Workflow::Definition.

=head1 METHODS

=head2 Init

Marks the annotated method as the workflow initializer (C<:Init>). Base-class attribute handler; see spec section 10.1.

=head2 Query

Marks the annotated method as a query handler (C<:Query>). Base-class attribute handler.

=head2 Signal

Marks the annotated method as a signal handler (C<:Signal>). Base-class attribute handler.

=head2 Update

Marks the annotated method as an update handler (C<:Update>). Base-class attribute handler.

=cut
