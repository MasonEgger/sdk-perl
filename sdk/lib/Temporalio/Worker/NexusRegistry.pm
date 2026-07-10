# ABOUTME: Builds the worker's Nexus service registry (spec section 26.2).
# ABOUTME: Resolves class names / instances to service => { operation => callable }; rejects dupes.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();

use Temporalio::Nexus::Definition ();
use Temporalio::Exception::Argument ();

class Temporalio::Worker::NexusRegistry {
    # service name => {
    #   instance   => the shared Nexus::Definition instance,
    #   operations => { op_name => { code => $callable->($ctx, $input),
    #                                kind => 'sync'|'workflow_run' } },
    # }
    field %services;

    field $nexus_services :param = [];

    ADJUST {
        for my $entry (@$nexus_services) {
            _add_entry($entry, \%services);
        }
    }

    # Returns the service => { instance, operations } hash.
    method services { return { %services } }

    # Look up one service (undef if absent).
    method service ($name) { return $services{$name} }

    # Look up one operation: ($service, $operation) -> { code, kind } or undef.
    method operation ($service, $operation) {
        my $svc = $services{$service} or return undef;
        return $svc->{operations}{$operation};
    }

    # Add one Nexus service entry (class name string or Definition instance).
    # Helper subs live inside the class block so they are callable from ADJUST
    # (a bare `class` file puts file-scope subs in main::, per lessons.md).
    sub _add_entry ($entry, $svcs) {
        if (Scalar::Util::blessed($entry)
            && $entry->isa('Temporalio::Nexus::Definition')) {
            _register_class($svcs, ref($entry), $entry);
            return;
        }

        if (!ref($entry) && length $entry) {
            my $loaded = eval { require(($entry =~ s{::}{/}gr) . '.pm'); 1 };
            if (!$loaded && !$entry->can('_nexus_operations')) {
                Temporalio::Exception::Argument->throw(
                    message => "Cannot load Nexus service class '$entry': $@",
                );
            }
            if (!$entry->isa('Temporalio::Nexus::Definition')) {
                Temporalio::Exception::Argument->throw(
                    message => "Nexus service class '$entry' does not inherit "
                        . "Temporalio::Nexus::Definition",
                );
            }
            _register_class($svcs, $entry, $entry->new);
            return;
        }

        Temporalio::Exception::Argument->throw(
            message => "Invalid Nexus service entry: expected a class name or a "
                . "Temporalio::Nexus::Definition instance",
        );
    }

    # Register every operation of a service class under its resolved service
    # name, binding each operation to the shared instance.
    sub _register_class ($svcs, $class, $instance) {
        my $name = $class->_nexus_service_name;
        if (exists $svcs->{$name}) {
            Temporalio::Exception::Argument->throw(
                message => "More than one Nexus service named '$name'",
            );
        }
        my $ops = $class->_nexus_operations;
        my %built;
        for my $op (keys %$ops) {
            my $method_ref = $ops->{$op}{code};
            $built{$op} = {
                code => sub { $instance->$method_ref(@_) },
                kind => $ops->{$op}{kind},
            };
        }
        $svcs->{$name} = { instance => $instance, operations => \%built };
        return;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::NexusRegistry - build the worker's Nexus service registry

=head1 SYNOPSIS

    my $reg = Temporalio::Worker::NexusRegistry->new(
        nexus_services => [
            'My::NexusService',        # class name
            My::Stateful->new,         # instance (shares state)
        ],
    );

    my $op = $reg->operation('test-service', 'say-hello');  # { code, kind }

=head1 DESCRIPTION

Builds the Nexus service registry described in spec section 26.2: a map from
service name to its operations. The C<nexus_services> list accepts class names
of L<Temporalio::Nexus::Definition> subclasses and pre-constructed instances.

Each registered operation C<code> is a code ref invoked as
C<< $code->($ctx, $input) >> bound to the shared service instance. Duplicate
service names, and unloadable or non-Definition entries, raise
L<Temporalio::Exception::Argument>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Worker::NexusRegistry->new(nexus_services => ...);

Named parameters:

=over 4

=item C<nexus_services>

(optional, default C<[]>)

=back

=head1 METHODS

=head2 operation

C<< $reg->operation($service, $operation) >> returns the operation definition
(C<< { code, kind } >>) or undef.

=head2 service

C<< $reg->service($name) >> returns the service entry (C<< { instance, operations } >>) or undef.

=head2 services

Returns all registered services.

=cut
