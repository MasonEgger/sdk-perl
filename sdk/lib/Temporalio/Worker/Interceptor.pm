# ABOUTME: Worker interceptor base classes (spec section 27.1/27.2).
# ABOUTME: intercept_activity/intercept_workflow return inbound instances; outbound base too.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Interceptor::Input ();
use Temporalio::Exception::Argument ();

# --- Input classes (spec section 27.1) -------------------------------------
# Field shape MUST-matched to sdk-python worker/_interceptor.py. Classic @ISA
# over the data-carrier base (see Temporalio::Interceptor::Input).
{
    no strict 'refs';
    for my $name (qw(
        ExecuteActivity Heartbeat
        ExecuteWorkflow HandleSignal HandleQuery HandleUpdate
        StartActivity StartLocalActivity StartChildWorkflow
        SignalChildWorkflow SignalExternalWorkflow ContinueAsNew
        StartNexusOperation Info
        ExecuteNexusOperationStart ExecuteNexusOperationCancel
    )) {
        @{ "Temporalio::Worker::Interceptor::Input::${name}::ISA" } =
            ('Temporalio::Interceptor::Input');
    }
}

# --- Activity inbound base (spec section 27.1) -----------------------------
# NOTE: methods are deliberately signature-less (args read from @_) — see the
# note in Temporalio::Client::Interceptor: a `field :param = <default>` next to
# a signatured method poisons the 5.38 `feature 'class'` parser once
# Future::AsyncAwait is loaded process-wide.
class Temporalio::Worker::ActivityInbound {
    field $next :param = undef;
    method next { $next }

    method init             { $next ? $next->init($_[0]) : () }
    method execute_activity { $next->execute_activity($_[0]) }
}

# --- Activity outbound base (spec R72) -------------------------------------
# Wraps the calls an activity BODY makes back out through its context. The
# method set MUST-matches sdk-python's ActivityOutboundInterceptor
# (worker/_interceptor.py:135-156, spec R72 parity finding 2): info and
# heartbeat, each delegating to next by default. Both carry an Input like
# every other chain method (Python's info() takes none and heartbeat takes
# *details): info's Input holds only the private `_root`, and heartbeat's
# details ride the Input's writable `args` field so an interceptor can rewrite
# them — a documented spec §0 surface deviation, same as WorkflowOutbound's
# info below. An interceptor installs a wrapper from its activity-inbound
# init($outbound): wrap the received outbound and delegate
# $self->next->init($wrapped); the ActivityDispatcher builds a root outbound,
# calls init on the inbound chain, and the Activity::Context routes the body's
# heartbeat()/info() through whatever outbound reaches the chain root.
class Temporalio::Worker::ActivityOutbound {
    field $next :param = undef;
    method next { $next }

    method info      { $next->info($_[0]) }
    method heartbeat { $next->heartbeat($_[0]) }
}

# --- Nexus operation inbound base (spec R73) -------------------------------
# Wraps Nexus operation starting and cancelling. The method set MUST-matches
# sdk-python's NexusOperationInboundInterceptor (worker/_interceptor.py:500-528,
# spec R73 parity finding 3): execute_nexus_operation_start and
# execute_nexus_operation_cancel, each delegating to next by default. Unlike
# the activity/workflow inbounds there is NO init/outbound side (Python has
# none either); the chain root runs the handler via the input's private
# `_root` coderef. The start input carries the operation context in `ctx` and
# the operation input riding the writable `args` field (Python's single
# mutable `input`, a documented spec section 0 surface deviation matching the
# R72 heartbeat-details precedent); the cancel input carries `ctx` and `token`
# (worker/_interceptor.py:485-497).
class Temporalio::Worker::NexusOperationInbound {
    field $next :param = undef;
    method next { $next }

    method execute_nexus_operation_start  { $next->execute_nexus_operation_start($_[0]) }
    method execute_nexus_operation_cancel { $next->execute_nexus_operation_cancel($_[0]) }
}

# --- Workflow inbound base (spec section 27.1) -----------------------------
# WorkflowInbound runs under $Runner::CURRENT and MUST be deterministic.
class Temporalio::Worker::WorkflowInbound {
    field $next :param = undef;
    method next { $next }

    method init             { $next ? $next->init($_[0]) : () }
    method execute_workflow { $next->execute_workflow($_[0]) }
    method handle_signal    { $next->handle_signal($_[0]) }
    method handle_query     { $next->handle_query($_[0]) }
    method validate_update  { $next->validate_update($_[0]) }
    method handle_update    { $next->handle_update($_[0]) }
}

# --- Workflow outbound base (spec section 27.1) ----------------------------
# These run on the workflow scheduler thread and MUST be deterministic. The
# method set MUST-matches sdk-python's WorkflowOutboundInterceptor
# (worker/_interceptor.py:416-481, spec R71 parity finding 1); the Perl names
# keep the SDK's execute_* surface verbs where Python says start_* (the calls
# route from execute_activity/start_activity et al. either way). info carries
# an Input like every other method (Python's info() takes none) so the chain
# root can use the shared `_root` coderef convention: a documented spec §0
# surface deviation.
class Temporalio::Worker::WorkflowOutbound {
    field $next :param = undef;
    method next { $next }

    method execute_activity        { $next->execute_activity($_[0]) }
    method execute_local_activity  { $next->execute_local_activity($_[0]) }
    method start_child_workflow    { $next->start_child_workflow($_[0]) }
    method signal_child_workflow   { $next->signal_child_workflow($_[0]) }
    method signal_external_workflow{ $next->signal_external_workflow($_[0]) }
    method continue_as_new         { $next->continue_as_new($_[0]) }
    method start_nexus_operation   { $next->start_nexus_operation($_[0]) }
    method info                    { $next->info($_[0]) }
}

# --- Interceptor base (spec section 27.1) ----------------------------------
# Ruby's instance-returning shape (resolved decision): intercept_activity($next)
# -> ActivityInbound, intercept_workflow($next) -> WorkflowInbound. Defaults
# return $next unchanged (no-op interceptor).
class Temporalio::Worker::Interceptor {
    method intercept_activity        { return $_[0] }
    method intercept_workflow        { return $_[0] }
    method intercept_nexus_operation { return $_[0] }
}

# --- Chain builders (spec section 27.2) ------------------------------------
# First-listed interceptor is OUTERMOST: iterate in reverse, each wrapping the
# accumulator over the root impl. Non-conforming returns die (spec 27.3). All
# three per-kind builders share the one fold below (spec R73 unification: the
# nexus fold is the same reduce sdk-python runs for its middleware,
# _interceptor.py:66-78,500-528 via _nexus.py:666-673, parity finding 3);
# $hook is the Interceptor method to call and $inbound_class the required
# return type.
sub _fold_inbound ($interceptors, $root, $hook, $inbound_class) {
    my $chain = $root;
    for my $i (reverse @{ $interceptors // [] }) {
        _assert_worker_interceptor($i);
        my $wrapped = $i->$hook($chain);
        unless (Scalar::Util::blessed($wrapped)
            && $wrapped->isa($inbound_class))
        {
            Temporalio::Exception::Argument->throw(
                message => "$hook must return a $inbound_class");
        }
        $chain = $wrapped;
    }
    return $chain;
}

sub Temporalio::Worker::Interceptor::build_activity_inbound ($interceptors, $root) {
    return _fold_inbound($interceptors, $root,
        'intercept_activity', 'Temporalio::Worker::ActivityInbound');
}

sub Temporalio::Worker::Interceptor::build_workflow_inbound ($interceptors, $root) {
    return _fold_inbound($interceptors, $root,
        'intercept_workflow', 'Temporalio::Worker::WorkflowInbound');
}

sub Temporalio::Worker::Interceptor::build_nexus_operation_inbound ($interceptors, $root) {
    return _fold_inbound($interceptors, $root,
        'intercept_nexus_operation', 'Temporalio::Worker::NexusOperationInbound');
}

# Build a full inbound + outbound chain PAIR (spec R71/R72, parity findings 1
# and 2; MUST-match sdk-python's init-driven install, worker/_interceptor.py
# :113-128 and :416-481 via _workflow_instance.py:392-398 / _activity.py
# :709-713): construct the root inbound with an on_init capture, fold the
# interceptor list over it with $fold (first-listed outermost), then call
# init(root outbound) on the finished inbound chain. Each interceptor inbound
# may WRAP the outbound it receives before delegating init down-chain, so
# whatever arrives at the ROOT inbound is the finished outbound chain
# (last-listed wrapper outermost, Python's exact init semantics); the capture
# hands it back. Shared by the workflow Runner (R71) and the
# ActivityDispatcher (R72). $inbound_root_class and $outbound_root_class are
# names of ALREADY-LOADED classes (the callers load their _Root* modules; this
# module cannot use them without a circular-load hazard against the base
# classes above).
sub Temporalio::Worker::Interceptor::build_chains (
    $interceptors, $fold, $inbound_root_class, $outbound_root_class, $kind)
{
    my $outbound;
    my $inbound = $fold->(
        $interceptors,
        $inbound_root_class->new(on_init => sub { $outbound = $_[0] }));
    $inbound->init($outbound_root_class->new);
    # An inbound that overrides init but never delegates strands the run with
    # no outbound chain; fail loudly at build time (Python surfaces the same
    # bug later, as an AttributeError on first outbound use).
    unless (defined $outbound) {
        Temporalio::Exception::Argument->throw(
            message => "${kind}-inbound interceptor init() did not "
                     . 'reach the chain root: init must delegate '
                     . '$self->next->init($outbound)');
    }
    return ($inbound, $outbound);
}

sub _assert_worker_interceptor ($i) {
    unless (Scalar::Util::blessed($i)
        && $i->isa('Temporalio::Worker::Interceptor'))
    {
        Temporalio::Exception::Argument->throw(
            message => 'worker interceptors must extend '
                     . 'Temporalio::Worker::Interceptor');
    }
    return;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::Interceptor - worker interceptor base classes

=head1 DESCRIPTION

Defines the worker interceptor surfaces (spec section 27.1):

=over 4

=item * L<Temporalio::Worker::Interceptor> with C<intercept_activity($next)>
returning a L<Temporalio::Worker::ActivityInbound>,
C<intercept_workflow($next)> returning a L<Temporalio::Worker::WorkflowInbound>,
and C<intercept_nexus_operation($next)> returning a
L<Temporalio::Worker::NexusOperationInbound> (Ruby's instance-returning
shape). Defaults return C<$next> unchanged.

=item * L<Temporalio::Worker::ActivityInbound>: C<init($outbound)>,
C<execute_activity($input)>.

=item * L<Temporalio::Worker::ActivityOutbound>: C<info>, C<heartbeat> (spec
R72; the method set matches sdk-python's C<ActivityOutboundInterceptor>,
C<worker/_interceptor.py:135-156>). An interceptor installs an outbound
wrapper from its activity-inbound C<init($outbound)>: wrap the received
outbound and delegate C<< $self->next->init($wrapped) >>. The
ActivityDispatcher builds a root outbound, calls C<init> on the inbound
chain, and the L<Temporalio::Activity::Context> routes the body's
C<heartbeat()>/C<info()> through whatever outbound reaches the chain root.
Heartbeat details ride the Input's writable C<args> field (Python's
C<*details>).

=item * L<Temporalio::Worker::NexusOperationInbound>:
C<execute_nexus_operation_start>, C<execute_nexus_operation_cancel> (spec R73;
the method set matches sdk-python's C<NexusOperationInboundInterceptor>,
C<worker/_interceptor.py:500-528>). No init/outbound side (Python has none
either). The NexusDispatcher folds the interceptor list over a
handler-running root on every start/cancel. The start input carries the
operation context in C<ctx> and the operation input riding the writable
C<args> field; the cancel input carries C<ctx> and C<token>.

=item * L<Temporalio::Worker::WorkflowInbound>: C<init($outbound)>,
C<execute_workflow>, C<handle_signal>, C<handle_query>, C<validate_update>,
C<handle_update>. Runs under C<$Runner::CURRENT> and must be deterministic.

=item * L<Temporalio::Worker::WorkflowOutbound>: C<execute_activity>,
C<execute_local_activity>, C<start_child_workflow>, C<signal_child_workflow>,
C<signal_external_workflow>, C<continue_as_new>, C<start_nexus_operation>,
C<info> (spec R71; the method set matches sdk-python's
C<WorkflowOutboundInterceptor>). An interceptor installs an outbound wrapper
from its workflow-inbound C<init($outbound)>: wrap the received outbound and
delegate C<< $self->next->init($wrapped) >>. The workflow Runner builds a root
outbound, calls C<init> on the inbound chain, and routes the eight operations
through whatever outbound reaches the chain root.

=item * Input classes under C<Temporalio::Worker::Interceptor::Input::*>.

=back

=head1 FUNCTIONS

=head2 build_activity_inbound / build_workflow_inbound / build_nexus_operation_inbound

C<< Temporalio::Worker::Interceptor::build_activity_inbound(\@interceptors, $root) >>
and the workflow and nexus-operation variants fold the list so the
first-listed interceptor is outermost, wrapping C<$root>. All three share one
fold (spec R73). Non-conforming interceptors or returns die.

=head2 build_chains

C<< Temporalio::Worker::Interceptor::build_chains(\@interceptors, \&fold,
$inbound_root_class, $outbound_root_class, $kind) >> builds a full inbound +
outbound chain pair (spec R71/R72): it constructs the root inbound with an
C<on_init> capture, folds the list over it with C<\&fold>, and calls
C<init(root outbound)> on the finished inbound chain so each interceptor
inbound may wrap the outbound on the way down (sdk-python's init semantics).
Returns C<($inbound, $outbound)>; dies if an inbound C<init> override fails
to delegate down to the chain root.

=cut
