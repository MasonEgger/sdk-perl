# ABOUTME: A non-Temporal exception class used to drive T-wf-15c: when its class
# ABOUTME: is listed in the worker's workflow_failure_exception_types, throwing it
# ABOUTME: from a workflow body fails the WORKFLOW (FailWorkflowExecution); when
# ABOUTME: not listed, it would fail only the TASK.
package WfDef::CustomError;

use v5.38;
use warnings;

use overload q{""} => sub { $_[0]->{message} }, fallback => 1;

sub new ($class, %args) {
    return bless { message => $args{message} // 'custom error' }, $class;
}

sub throw ($class, %args) { die $class->new(%args) }

sub message ($self) { return $self->{message} }

1;
