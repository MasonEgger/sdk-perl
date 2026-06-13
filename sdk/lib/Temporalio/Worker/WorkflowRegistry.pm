# ABOUTME: Builds the worker's workflow registry (spec section 8.6).
# ABOUTME: Resolves workflow class names to type => class; requires one :Run each; rejects dupes.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();

use Temporalio::Workflow::Definition ();
use Temporalio::Exception::Argument ();

class Temporalio::Worker::WorkflowRegistry {
    # workflow type name => backing class (a Temporalio::Workflow::Definition
    # subclass with exactly one :Run method).
    field %definitions;

    field $workflows :param = [];

    ADJUST {
        for my $entry (@$workflows) {
            _add_entry($entry, \%definitions);
        }
    }

    # Returns the type => class hash.
    method definitions { return { %definitions } }

    # Look up a single workflow's backing class by type name (undef if absent).
    method definition ($name) { return $definitions{$name} }

    # Add one workflow entry. Helper subs live inside the class block so they
    # are callable from ADJUST (a bare `class` file puts file-scope subs in
    # main::, per lessons.md).
    sub _add_entry ($entry, $defs) {
        if (!ref($entry) && length $entry) {
            # A workflow class name. Require it lazily in case the caller has
            # not loaded it yet.
            my $loaded = eval { require(($entry =~ s{::}{/}gr) . '.pm'); 1 };
            if (!$loaded && !$entry->can('_workflow_defs')) {
                Temporalio::Exception::Argument->throw(
                    message => "Cannot load workflow class '$entry': $@",
                );
            }
            if (!$entry->isa('Temporalio::Workflow::Definition')) {
                Temporalio::Exception::Argument->throw(
                    message => "Workflow class '$entry' does not inherit "
                        . "Temporalio::Workflow::Definition",
                );
            }

            my $wf_defs = $entry->_workflow_defs;
            if (!defined $wf_defs->{run}) {
                Temporalio::Exception::Argument->throw(
                    message => "Workflow class '$entry' has no :Run method",
                );
            }

            my $type = $entry->_workflow_type;
            _register($defs, $type, $entry);
            return;
        }

        Temporalio::Exception::Argument->throw(
            message => "Invalid workflow entry: expected the name of a "
                . "Temporalio::Workflow::Definition subclass",
        );
    }

    sub _register ($defs, $name, $class) {
        if (exists $defs->{$name}) {
            Temporalio::Exception::Argument->throw(
                message => "More than one workflow named '$name'",
            );
        }
        $defs->{$name} = $class;
        return;
    }
}

1;

__END__

=head1 NAME

Temporalio::Worker::WorkflowRegistry - build the worker's workflow registry

=head1 SYNOPSIS

    my $reg = Temporalio::Worker::WorkflowRegistry->new(
        workflows => ['My::Workflow::Greeting', 'My::Workflow::Order'],
    );

    my $class = $reg->definition('Greeting');   # 'My::Workflow::Greeting'

=head1 DESCRIPTION

Builds the workflow registry described in spec section 8.6: a map from
workflow type name to the backing L<Temporalio::Workflow::Definition>
subclass. The C<workflows> list accepts class names of such subclasses; each
must declare exactly one C<:Run> method (the workflow type defaults to the
class basename, overridable via C<:Run('CustomName')>).

Duplicate workflow type names raise L<Temporalio::Exception::Argument> (spec
test T-wkr-2, workflow side), as does an entry that is not the name of a
loadable C<Temporalio::Workflow::Definition> subclass, or a subclass with no
C<:Run> method.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Worker::WorkflowRegistry->new(
        workflows => ...,
    );

Constructs a Temporalio::Worker::WorkflowRegistry. Named parameters:

=over 4

=item C<workflows>

(optional, default C<[]>)

=back

=head1 METHODS

=head2 definition

Returns the workflow definition registered under the given workflow type, or undef.

=head2 definitions

Returns all registered workflow definitions.

=cut
