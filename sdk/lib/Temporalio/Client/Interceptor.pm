# ABOUTME: Client interceptor base classes + outbound chain (spec section 27.1/27.2).
# ABOUTME: intercept_client($next) -> OutboundInterceptor; default methods delegate to next.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Interceptor::Input ();
use Temporalio::Exception::Argument ();

# --- Input classes (spec section 27.1) -------------------------------------
# Thin subclasses of the shared (classic-package) backing store; field shape
# MUST-matched to sdk-python client/_interceptor.py StartWorkflowInput /
# SignalWorkflowInput / QueryWorkflowInput / StartWorkflowUpdateInput.
# SignalWithStartWorkflowInput has no top-level headers (they live on the
# embedded start op, spec 27.1). Classic @ISA so they inherit the data-carrier
# new/get/set without `feature 'class'` :param validation.
{
    no strict 'refs';
    for my $name (qw(StartWorkflow SignalWithStartWorkflow SignalWorkflow
                     QueryWorkflow StartWorkflowUpdate)) {
        @{ "Temporalio::Client::Interceptor::Input::${name}::ISA" } =
            ('Temporalio::Interceptor::Input');
    }
}

# --- OutboundInterceptor base (spec section 27.1) --------------------------
# Each method takes one Input and returns a Future. The default body delegates
# to $self->next->$method($input). The chain root (an OutboundInterceptor
# subclass whose `next` is undef) performs the real RPC; user interceptors
# extend this and call $self->next->... to continue the chain.
# NOTE: methods are deliberately signature-less (args read from @_). A
# `field :param = <default>` adjacent to a signatured method poisons the
# perl 5.38 `feature 'class'` parser once Future::AsyncAwait's parser hook is
# loaded process-wide (the SDK loads it broadly). Signature-less methods sit
# fine alongside :param defaults — the same shape used in Nexus/OperationContext.
class Temporalio::Client::OutboundInterceptor {
    field $next :param = undef;
    method next { $next }

    method start_workflow { $next->start_workflow($_[0]) }
    method signal_with_start_workflow {
        $next->signal_with_start_workflow($_[0]);
    }
    method signal_workflow       { $next->signal_workflow($_[0]) }
    method query_workflow        { $next->query_workflow($_[0]) }
    method start_workflow_update { $next->start_workflow_update($_[0]) }
}

# --- Interceptor base (spec section 27.1) ----------------------------------
# intercept_client($next) -> OutboundInterceptor. The default returns $next
# unchanged (no-op interceptor). User subclasses override it to return their
# own OutboundInterceptor subclass wrapping $next.
class Temporalio::Client::Interceptor {
    method intercept_client { return $_[0] }
}

# build_outbound_chain(\@interceptors, $root) -> OutboundInterceptor
# Folds the interceptor list so the FIRST-listed interceptor is OUTERMOST
# (spec section 27.2): iterate in reverse, each intercept_client($next)
# wrapping the accumulator over $root (which performs the real RPC). A
# non-conforming return value is a load-time die (spec section 27.3).
sub Temporalio::Client::Interceptor::build_outbound_chain ($interceptors, $root) {
    my $chain = $root;
    for my $i (reverse @{ $interceptors // [] }) {
        unless (Scalar::Util::blessed($i)
            && $i->isa('Temporalio::Client::Interceptor'))
        {
            Temporalio::Exception::Argument->throw(
                message => 'client interceptors must extend '
                         . 'Temporalio::Client::Interceptor');
        }
        my $wrapped = $i->intercept_client($chain);
        unless (Scalar::Util::blessed($wrapped)
            && $wrapped->isa('Temporalio::Client::OutboundInterceptor'))
        {
            Temporalio::Exception::Argument->throw(
                message => 'intercept_client must return a '
                         . 'Temporalio::Client::OutboundInterceptor');
        }
        $chain = $wrapped;
    }
    return $chain;
}

use Scalar::Util ();

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::Interceptor - client interceptor base classes

=head1 DESCRIPTION

Defines the client interceptor surface (spec section 27.1):

=over 4

=item * L<Temporalio::Client::Interceptor> with C<intercept_client($next)>
returning an OutboundInterceptor. The default returns C<$next> unchanged.

=item * L<Temporalio::Client::OutboundInterceptor> with C<start_workflow>,
C<signal_with_start_workflow>, C<signal_workflow>, C<query_workflow>, and
C<start_workflow_update>, each taking one Input and returning a Future. Default
methods delegate to C<< $self->next >>.

=item * The Input classes under C<Temporalio::Client::Interceptor::Input::*>,
each a subclass of L<Temporalio::Interceptor::Input> (writable C<args>/
C<headers>, read-only everything else).

=back

=head1 FUNCTIONS

=head2 build_outbound_chain

C<< Temporalio::Client::Interceptor::build_outbound_chain(\@interceptors, $root) >>
folds the interceptor list so the first-listed interceptor is outermost,
wrapping C<$root> (the OutboundInterceptor that performs the real RPC). Returns
the chain head. Dies if any interceptor or returned wrapper is non-conforming.

=cut
