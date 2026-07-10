# ABOUTME: Builds the worker's activity registry (spec section 8.5).
# ABOUTME: Resolves class names, instances, and FunctionDefinitions to type => callable; rejects dupes.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();

use Temporalio::Activity::Definition ();
use Temporalio::Activity::FunctionDefinition ();
use Temporalio::Exception::Argument ();

class Temporalio::Worker::ActivityRegistry {
    # activity type name => {
    #   code                   => $callable invoked as $code->(@args),
    #   no_thread_cancellation => 0|1,
    #   sync                   => 0|1,   # sync => fork pool; async => main loop
    # }
    field %definitions;

    field $activities :param = [];

    ADJUST {
        for my $entry (@$activities) {
            _add_entry($entry, \%definitions);
        }
    }

    # Returns the type => definition hash.
    method definitions { return { %definitions } }

    # Look up a single activity definition by type name (undef if absent).
    method definition ($name) { return $definitions{$name} }

    # True if any registered activity is sync-declared (so the worker needs to
    # build the fork pool — spec section 9.4).
    method has_sync_activities {
        for my $def (values %definitions) {
            return 1 if $def->{sync};
        }
        return 0;
    }

    # Add one activity entry (class name string, Definition instance, or
    # FunctionDefinition). Helper subs live inside the class block so they are
    # callable from ADJUST (a bare `class` file puts file-scope subs in main::,
    # per lessons.md).
    sub _add_entry ($entry, $defs) {
        if (Scalar::Util::blessed($entry)
            && $entry->isa('Temporalio::Activity::FunctionDefinition')) {
            _register($defs, $entry->name, {
                code                   => $entry->code,
                no_thread_cancellation => $entry->no_thread_cancellation,
                sync                   => $entry->sync ? 1 : 0,
            });
            return;
        }

        if (Scalar::Util::blessed($entry)
            && $entry->isa('Temporalio::Activity::Definition')) {
            # A pre-constructed instance: activities can share state this way.
            _register_class_defs($defs, ref($entry), $entry);
            return;
        }

        if (!ref($entry) && length $entry) {
            # A class name. The class must inherit the Definition base. Require
            # it lazily in case the caller has not loaded it yet, then build a
            # fresh instance per dispatch.
            my $loaded = eval { require(($entry =~ s{::}{/}gr) . '.pm'); 1 };
            if (!$loaded && !$entry->can('_activity_defs')) {
                Temporalio::Exception::Argument->throw(
                    message => "Cannot load activity class '$entry': $@",
                );
            }
            if (!$entry->isa('Temporalio::Activity::Definition')) {
                Temporalio::Exception::Argument->throw(
                    message => "Activity class '$entry' does not inherit "
                        . "Temporalio::Activity::Definition",
                );
            }
            _register_class_defs($defs, $entry, undef);
            return;
        }

        Temporalio::Exception::Argument->throw(
            message => "Invalid activity entry: expected a class name, a "
                . "Temporalio::Activity::Definition instance, or a "
                . "Temporalio::Activity::FunctionDefinition",
        );
    }

    # Register every :Defn method of a class. $instance, when defined, is the
    # shared instance to invoke; otherwise a fresh instance is built per call.
    sub _register_class_defs ($defs, $class, $instance) {
        my $class_defs = $class->_activity_defs;
        for my $type (keys %$class_defs) {
            my $method_ref = $class_defs->{$type}{code};
            my $code = defined $instance
                ? sub { $instance->$method_ref(@_) }
                : sub { my $inst = $class->new; $inst->$method_ref(@_) };
            _register($defs, $type, {
                code                   => $code,
                no_thread_cancellation => $class_defs->{$type}{no_thread_cancellation},
                sync                   => $class_defs->{$type}{sync} ? 1 : 0,
            });
        }
    }

    sub _register ($defs, $name, $def) {
        if (exists $defs->{$name}) {
            Temporalio::Exception::Argument->throw(
                message => "More than one activity named '$name'",
            );
        }
        $defs->{$name} = $def;
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::ActivityRegistry - build the worker's activity registry

=head1 SYNOPSIS

    my $reg = Temporalio::Worker::ActivityRegistry->new(
        activities => [
            'My::Activity::SayHello',          # class name
            My::Activity::Stateful->new,       # instance (shares state)
            $function_definition,              # FunctionDefinition
        ],
    );

    my $def = $reg->definition('SayHello');    # { code => $callable, ... }

=head1 DESCRIPTION

Builds the activity registry described in spec section 8.5: a map from
activity type name to a callable. The C<activities> list accepts class names
of L<Temporalio::Activity::Definition> subclasses, pre-constructed instances
of such classes (so multiple activities can share state), and
L<Temporalio::Activity::FunctionDefinition> objects.

Each registered C<code> is a plain code ref invoked as C<< $code->(@args) >>:
for a class name a fresh instance is built per dispatch; for an instance the
shared instance is reused; for a function definition the supplied code ref is
called directly.

Duplicate activity type names raise L<Temporalio::Exception::Argument>, as
does an entry that is neither a loadable Definition subclass name, a
Definition instance, nor a FunctionDefinition (spec test T-wkr-2).

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Worker::ActivityRegistry->new(
        activities => ...,
    );

Constructs a Temporalio::Worker::ActivityRegistry. Named parameters:

=over 4

=item C<activities>

(optional, default C<[]>)

=back

=head1 METHODS

=head2 definition

Returns the activity definition registered under the given name, or undef.

=head2 definitions

Returns all registered activity definitions.

=head2 has_sync_activities

Returns true if any registered activity runs synchronously (and therefore needs the fork pool).

=cut
