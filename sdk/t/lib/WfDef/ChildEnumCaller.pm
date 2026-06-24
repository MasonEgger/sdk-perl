# ABOUTME: Fixture workflow that starts a child with non-default enum options to
# ABOUTME: exercise the parent_close_policy / cancellation_type string mapping
# ABOUTME: (T-child-10). The option strings are passed in as run arguments.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts a child whose enum options are supplied by the test. A bad
# enum string must die at scheduling time (start_child_workflow throws before
# the command is buffered), which the body lets escape :Run.
class WfDef::ChildEnumCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run (%opts) {
        my $handle = await Temporalio::Workflow::start_child_workflow(
            'GreetingChild',
            id => 'child-1',
            %opts,
        );
        return $handle->id;
    }
}

1;
