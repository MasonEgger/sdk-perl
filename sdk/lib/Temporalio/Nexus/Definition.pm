# ABOUTME: Base class for class-based Nexus service definitions (spec section 26.2, 10.1).
# ABOUTME: Hosts the :NexusService/:SyncOperation/:WorkflowRunOperation handlers + per-class registry.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

# The four constraints in spec section 10.1 (proven in t/spike/) apply here:
#   1. This base MUST be declared with `class`, not `package`.
#   2. The attribute handlers MUST live in the inheritance chain (this class).
#   3. The handlers MUST use :ATTR(CODE,BEGIN) — workers `require` user nexus
#      modules at runtime, after the global CHECK pass.
#   4. $data arrives as ARRAYREF or undef, never a bare string.
#
# NOTE on :NexusService. The spec example writes :NexusService('name') as a
# CLASS attribute (`class My::Svc :isa(...) :NexusService('name')`). Perl's
# `feature 'class'` rejects custom CLASS attributes ("Unrecognized class
# attribute") — only CODE attributes are honored (proven in t/spike/). So
# :NexusService is implemented as a CODE attribute applied to ANY one method
# of the service: it sets the per-class service name. The service name still
# defaults to the class basename when no :NexusService attribute is present
# (spec section 26.2: "default: class name"). The operation attributes
# (:SyncOperation / :WorkflowRunOperation) are the load-bearing section 10.1
# handlers and behave exactly as the spec describes.
class Temporalio::Nexus::Definition {
    use Attribute::Handlers;

    # Per-class registry keyed by package name:
    #   { service    => 'service-name',           # resolved service name
    #     operations => { op_name => { code => $methodref, kind => 'sync'|'workflow_run' } } }
    our %_DEFS;

    # :NexusService('name') — names the service. A CODE attribute (see the note
    # above); the method it decorates is otherwise untouched. Default service
    # name (no attribute) is the class basename, resolved lazily by
    # _nexus_service_name.
    sub NexusService :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        my @items = ref($data) eq 'ARRAY' ? @$data : (defined $data ? ($data) : ());
        my $name = $items[0];
        if (!defined $name || !length $name) {
            Temporalio::Exception::Argument->throw(
                message => ":NexusService requires a service name on $pkg",
            );
        }
        if (defined $_DEFS{$pkg}{service} && $_DEFS{$pkg}{service} ne $name) {
            Temporalio::Exception::Argument->throw(
                message => "Conflicting :NexusService names on $pkg "
                    . "('$_DEFS{$pkg}{service}' vs '$name')",
            );
        }
        $_DEFS{$pkg}{service} = $name;
        return;
    }

    # :SyncOperation('name') — a synchronous operation handler. Signature
    # ($ctx, $input); returns the result value directly (the dispatcher wraps
    # it in StartOperationResponse.Sync). Name defaults to the method name.
    sub SyncOperation :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        _register_operation($pkg, *{$sym}{NAME}, $ref, $data, 'sync');
        return;
    }

    # :WorkflowRunOperation('name') — a workflow-backed operation handler.
    # Signature ($ctx, $input); calls $ctx->start_workflow(...) and returns a
    # Temporalio::Nexus::WorkflowHandle (the dispatcher emits
    # StartOperationResponse.Async{operation_token}). Name defaults to method.
    sub WorkflowRunOperation :ATTR(CODE,BEGIN) {
        my ($pkg, $sym, $ref, $attr, $data, $phase) = @_;
        _register_operation($pkg, *{$sym}{NAME}, $ref, $data, 'workflow_run');
        return;
    }

    # Register one operation under its resolved name; reject a duplicate within
    # the service (mirrors the workflow Definition's per-kind duplicate guard).
    # File-scope sub inside the class block so it is visible from the handlers
    # (a bare `class` file would put a file-scope sub in main::, per lessons.md).
    sub _register_operation ($pkg, $method_name, $ref, $data, $kind) {
        my @items = ref($data) eq 'ARRAY' ? @$data : (defined $data ? ($data) : ());
        my $name = (defined $items[0] && length $items[0]) ? $items[0] : $method_name;

        if (exists $_DEFS{$pkg}{operations}{$name}) {
            Temporalio::Exception::Argument->throw(
                message => "Multiple Nexus operations named '$name' on $pkg",
            );
        }
        $_DEFS{$pkg}{operations}{$name} = { code => $ref, kind => $kind };
        return;
    }

    # Class method: the resolved service name. Explicit :NexusService wins;
    # otherwise the class basename (spec section 26.2 default).
    sub _nexus_service_name ($class) {
        my $explicit = ($_DEFS{$class} // {})->{service};
        return $explicit if defined $explicit;
        (my $base = $class) =~ s/.*:://;
        return $base;
    }

    # Class method: the per-class operation registry, op_name => { code, kind }.
    sub _nexus_operations ($class) {
        return ($_DEFS{$class} // {})->{operations} // {};
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Nexus::Definition - base class for class-based Nexus services

=head1 SYNOPSIS

    package My::NexusService;
    use feature 'class';
    use Future::AsyncAwait;
    use Temporalio::Nexus;

    class My::NexusService :isa(Temporalio::Nexus::Definition) {
        method service_name :NexusService('test-service') ($) { }

        method say_hello :SyncOperation('say-hello') ($ctx, $name) {
            return "Hello, $name!";
        }

        async method echo :WorkflowRunOperation('echo') ($ctx, $input) {
            return await $ctx->start_workflow('EchoHandlerWorkflow', $input, id => ...);
        }
    }

    my $svc  = My::NexusService->_nexus_service_name;   # 'test-service'
    my $ops  = My::NexusService->_nexus_operations;     # { 'say-hello' => {...}, ... }

=head1 DESCRIPTION

Nexus service classes inherit this base and decorate their operation methods
with C<:SyncOperation> or C<:WorkflowRunOperation> (spec section 26.2). The
service name is set with C<:NexusService('name')> and defaults to the class
basename. Registration happens at the subclass's compile time via
L<Attribute::Handlers> (C<:ATTR(CODE,BEGIN)>), the correct phase for an SDK
whose users register services by C<require>-ing modules at worker startup.

C<:NexusService> is a B<code> attribute, not a class attribute: Perl's
C<feature 'class'> rejects custom class attributes, so the spec's class-level
surface is implemented by decorating any one method. The four section 10.1
constraints apply to all three handlers.

=head2 Attributes

=over 4

=item C<:NexusService('name')>

Names the Nexus service. Default (absent) is the class basename. A conflicting
second name raises L<Temporalio::Exception::Argument>.

=item C<:SyncOperation> / C<:SyncOperation('name')>

A synchronous operation: signature C<($ctx, $input)>, returns the result value
directly. Name defaults to the method name.

=item C<:WorkflowRunOperation> / C<:WorkflowRunOperation('name')>

A workflow-backed operation: signature C<($ctx, $input)>, calls
C<< $ctx->start_workflow(...) >> and returns a
L<Temporalio::Nexus::WorkflowHandle>. Name defaults to the method name.

=back

A duplicate operation name within one service raises
L<Temporalio::Exception::Argument>.

=head2 Class methods

=over 4

=item C<_nexus_service_name>

The resolved service name.

=item C<_nexus_operations>

The per-class C<< op_name => { code => $methodref, kind => 'sync'|'workflow_run' } >>
registry.

=back

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Nexus::Definition.

=head1 METHODS

=head2 NexusService

Base-class attribute handler naming the Nexus service (C<:NexusService>); see spec section 26.2.

=head2 SyncOperation

Base-class attribute handler marking a synchronous operation (C<:SyncOperation>).

=head2 WorkflowRunOperation

Base-class attribute handler marking a workflow-backed operation (C<:WorkflowRunOperation>).

=cut
