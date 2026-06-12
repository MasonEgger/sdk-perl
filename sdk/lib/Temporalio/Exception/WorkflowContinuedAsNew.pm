# ABOUTME: Raised by result(follow_runs => 0) when the run continued-as-new.
# ABOUTME: new_run_id identifies the successor run (spec section 6.2).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception;

class Temporalio::Exception::WorkflowContinuedAsNew :isa(Temporalio::Exception) {
    field $new_run_id :param = undef;

    method new_run_id             { $new_run_id }
}

1;

__END__

=head1 NAME

Temporalio::Exception::WorkflowContinuedAsNew - Raised by result(follow_runs => 0) when the run continued-as-new.

=head1 DESCRIPTION

Raised by C<< $handle->result(follow_runs => 0) >> when the workflow run continued-as-new instead of completing. C<new_run_id> identifies the successor run. See L<Temporalio::Exception> for the shared C<message>, C<stack_trace>, and C<cause> fields.

=cut
