# ABOUTME: Fixture workflow whose :Run throws a Temporalio::Exception::Application
# ABOUTME: — drives the FailWorkflowExecution outcome (T-wf-15b): a Temporal
# ABOUTME: failure exception fails the workflow execution (not the task).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;
use Temporalio::Exception::Application ();

class WfDef::AppFailer :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        Temporalio::Exception::Application->throw(
            message => 'app boom',
            type    => 'BoomError',
        );
    }
}

1;
