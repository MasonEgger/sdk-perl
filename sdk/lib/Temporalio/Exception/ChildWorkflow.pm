# ABOUTME: Failure wrapping a child workflow execution failure (spec section 6.2).
# ABOUTME: Maps to the child_workflow_execution_failure_info Failure proto variant.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::ChildWorkflow :isa(Temporalio::Exception) {
    field $namespace :param = undef;
    field $workflow_id :param = undef;
    field $run_id :param = undef;
    field $workflow_type :param = undef;
    field $retry_state :param = undef;
    field $initiated_event_id :param = undef;
    field $started_event_id :param = undef;

    method namespace              { $namespace }
    method workflow_id            { $workflow_id }
    method run_id                 { $run_id }
    method workflow_type          { $workflow_type }
    method retry_state            { $retry_state }
    method initiated_event_id     { $initiated_event_id }
    method started_event_id       { $started_event_id }
}

1;

__END__

=head1 NAME

Temporalio::Exception::ChildWorkflow - Failure wrapping a child workflow execution failure (spec section 6.2).

=head1 DESCRIPTION

Wraps a child workflow execution failure; the underlying error is the C<cause>. C<retry_state> is the lowercased suffix of the Temporal RetryState enum. Maps to the C<child_workflow_execution_failure_info> Failure proto variant. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Exception::ChildWorkflow->new(
        namespace => ...,
        workflow_id => ...,
        run_id => ...,
        workflow_type => ...,
        retry_state => ...,
        initiated_event_id => ...,
        started_event_id => ...,
    );

Constructs a Temporalio::Exception::ChildWorkflow. Named parameters:

=over 4

=item C<namespace>

(optional, default C<undef>)

=item C<workflow_id>

(optional, default C<undef>)

=item C<run_id>

(optional, default C<undef>)

=item C<workflow_type>

(optional, default C<undef>)

=item C<retry_state>

(optional, default C<undef>)

=item C<initiated_event_id>

(optional, default C<undef>)

=item C<started_event_id>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 initiated_event_id

Accessor returning the C<initiated_event_id> value.

=head2 namespace

Accessor returning the C<namespace> value.

=head2 retry_state

Accessor returning the C<retry_state> value.

=head2 run_id

Accessor returning the C<run_id> value.

=head2 started_event_id

Accessor returning the C<started_event_id> value.

=head2 workflow_id

Accessor returning the C<workflow_id> value.

=head2 workflow_type

Accessor returning the C<workflow_type> value.

=cut
