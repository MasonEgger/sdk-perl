# ABOUTME: Internal control-flow signal raised by Temporalio::Workflow::continue_as_new
# ABOUTME: (spec section 10.2/10.3 step 6). NOT a Temporalio::Exception subclass —
# ABOUTME: it must NOT be treated as a workflow-failure exception; the runner catches
# ABOUTME: it specially and emits ContinueAsNewWorkflowExecution.
package Temporalio::Workflow::ContinueAsNew;

use v5.38;
use warnings;

# Mirrors sdk-python's _ContinueAsNewError (raised from the workflow body to
# unwind the :Run coroutine, caught by the runner to emit the
# ContinueAsNewWorkflowExecution command instead of completing/failing). It is
# deliberately a PLAIN blessed object, not a Temporalio::Exception, so the
# decision table (spec section 10.3 step 6) never mistakes it for an
# application/Temporal failure: the runner identifies it by class.
#
# %opts mirror Temporalio::Workflow::continue_as_new (spec section 10.2):
#   workflow (type name string, optional; defaults to the current type),
#   args (arrayref), task_queue, retry_policy (Temporalio::Common::RetryPolicy),
#   memo (hashref), search_attributes
#   (Temporalio::Common::TypedSearchAttributes), headers (hashref),
#   run_timeout / task_timeout (seconds), versioning_intent ('compatible' or
#   'default', spec R25).
sub new ($class, %opts) {
    return bless { %opts }, $class;
}

# Accessor for the captured options (the runner reads these to build the
# ContinueAsNewWorkflowExecution command).
sub options ($self) { return %$self }

# Stringification so a stray `die` of this object outside the runner is at
# least legible (it should never escape the runner in practice).
use overload q{""} => sub { 'Temporalio::Workflow::ContinueAsNew' }, fallback => 1;

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Workflow::ContinueAsNew - internal continue-as-new control signal

=head1 DESCRIPTION

A plain blessed object C<die>n by L<Temporalio::Workflow/continue_as_new> to
unwind the C<:Run> coroutine. The L<Temporalio::Workflow::Runner> catches it
(by class) in its completion-outcome decision table (spec section 10.3 step 6)
and emits a C<ContinueAsNewWorkflowExecution> command rather than completing or
failing the workflow.

It is deliberately B<not> a L<Temporalio::Exception> subclass: were it one, the
outcome decision table would mistake it for a Temporal failure and emit
C<FailWorkflowExecution>. This mirrors sdk-python's C<_ContinueAsNewError>
handling, which is caught before the generic failure branch.

=head1 CONSTRUCTOR

=head2 new

    my $can = Temporalio::Workflow::ContinueAsNew->new(%opts);

Constructs the control object. C<%opts> mirror
L<Temporalio::Workflow/continue_as_new> (spec section 10.2): C<workflow> (type
name, optional; defaults to the current type), C<args> (arrayref),
C<task_queue>, C<retry_policy>, C<memo>, C<search_attributes>
(a L<Temporalio::Common::TypedSearchAttributes>), C<headers>,
C<run_timeout> / C<task_timeout> (seconds), and C<versioning_intent>
(C<'compatible'> or C<'default'>; omit for the server default).

=head1 METHODS

=head2 options

Returns the captured continue-as-new options as a flat key/value list (the
runner reads these to build the C<ContinueAsNewWorkflowExecution> command).

=cut
