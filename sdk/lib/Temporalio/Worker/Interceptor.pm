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
        ExecuteActivity
        ExecuteWorkflow HandleSignal HandleQuery HandleUpdate
        StartActivity StartLocalActivity StartChildWorkflow
        SignalChildWorkflow SignalExternalWorkflow ContinueAsNew
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
# These run on the workflow scheduler thread and MUST be deterministic.
class Temporalio::Worker::WorkflowOutbound {
    field $next :param = undef;
    method next { $next }

    method execute_activity        { $next->execute_activity($_[0]) }
    method execute_local_activity  { $next->execute_local_activity($_[0]) }
    method start_child_workflow    { $next->start_child_workflow($_[0]) }
    method signal_child_workflow   { $next->signal_child_workflow($_[0]) }
    method signal_external_workflow{ $next->signal_external_workflow($_[0]) }
    method continue_as_new         { $next->continue_as_new($_[0]) }
}

# --- Interceptor base (spec section 27.1) ----------------------------------
# Ruby's instance-returning shape (resolved decision): intercept_activity($next)
# -> ActivityInbound, intercept_workflow($next) -> WorkflowInbound. Defaults
# return $next unchanged (no-op interceptor).
class Temporalio::Worker::Interceptor {
    method intercept_activity { return $_[0] }
    method intercept_workflow { return $_[0] }
}

# --- Chain builders (spec section 27.2) ------------------------------------
# First-listed interceptor is OUTERMOST: iterate in reverse, each wrapping the
# accumulator over the root impl. Non-conforming returns die (spec 27.3).
sub Temporalio::Worker::Interceptor::build_activity_inbound ($interceptors, $root) {
    my $chain = $root;
    for my $i (reverse @{ $interceptors // [] }) {
        _assert_worker_interceptor($i);
        my $wrapped = $i->intercept_activity($chain);
        unless (Scalar::Util::blessed($wrapped)
            && $wrapped->isa('Temporalio::Worker::ActivityInbound'))
        {
            Temporalio::Exception::Argument->throw(
                message => 'intercept_activity must return a '
                         . 'Temporalio::Worker::ActivityInbound');
        }
        $chain = $wrapped;
    }
    return $chain;
}

sub Temporalio::Worker::Interceptor::build_workflow_inbound ($interceptors, $root) {
    my $chain = $root;
    for my $i (reverse @{ $interceptors // [] }) {
        _assert_worker_interceptor($i);
        my $wrapped = $i->intercept_workflow($chain);
        unless (Scalar::Util::blessed($wrapped)
            && $wrapped->isa('Temporalio::Worker::WorkflowInbound'))
        {
            Temporalio::Exception::Argument->throw(
                message => 'intercept_workflow must return a '
                         . 'Temporalio::Worker::WorkflowInbound');
        }
        $chain = $wrapped;
    }
    return $chain;
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
returning a L<Temporalio::Worker::ActivityInbound> and
C<intercept_workflow($next)> returning a L<Temporalio::Worker::WorkflowInbound>
(Ruby's instance-returning shape). Defaults return C<$next> unchanged.

=item * L<Temporalio::Worker::ActivityInbound>: C<init($outbound)>,
C<execute_activity($input)>.

=item * L<Temporalio::Worker::WorkflowInbound>: C<init($outbound)>,
C<execute_workflow>, C<handle_signal>, C<handle_query>, C<validate_update>,
C<handle_update>. Runs under C<$Runner::CURRENT> and must be deterministic.

=item * L<Temporalio::Worker::WorkflowOutbound>: C<execute_activity>,
C<execute_local_activity>, C<start_child_workflow>, C<signal_child_workflow>,
C<signal_external_workflow>, C<continue_as_new>.

=item * Input classes under C<Temporalio::Worker::Interceptor::Input::*>.

=back

=head1 FUNCTIONS

=head2 build_activity_inbound / build_workflow_inbound

C<< Temporalio::Worker::Interceptor::build_activity_inbound(\@interceptors, $root) >>
and the workflow variant fold the list so the first-listed interceptor is
outermost, wrapping C<$root>. Non-conforming interceptors or returns die.

=cut
