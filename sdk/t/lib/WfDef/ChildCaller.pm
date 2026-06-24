# ABOUTME: Fixture workflow that executes one child via execute_child_workflow
# ABOUTME: and returns its result — drives the start->result round trip
# ABOUTME: (T-child-1/3/4) in the child_workflows replay test.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run executes a single child workflow and returns its result. The first
# activation (InitializeWorkflow) parks the body on the child's start await and
# emits one StartChildWorkflowExecution command; a ResolveChildWorkflowExecutionStart
# resumes to the result await; a ResolveChildWorkflowExecution then resolves the
# body, which returns the (formatted) result. A child failure surfaces as
# Temporalio::Exception::ChildWorkflow at the await site and bubbles out of :Run.
class WfDef::ChildCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = 'Alice') {
        my $result = await Temporalio::Workflow::execute_child_workflow(
            'GreetingChild',
            id   => 'child-1',
            args => [$name],
        );
        return "got: $result";
    }
}

1;
