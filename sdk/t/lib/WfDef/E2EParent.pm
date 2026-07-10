# ABOUTME: Integration parent workflow — executes an E2EChild and returns its
# ABOUTME: result, or signals a started child then awaits its result. Drives the
# ABOUTME: child_workflows integration test (T-child-13).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Driven by ($mode, $arg):
#   'execute' -> execute_child_workflow('E2EChild', args=>[$arg]) and return its
#                result (or let a ChildWorkflow failure bubble).
#   'signal'  -> start a child in 'signal' mode, signal it 'poke' with $arg via
#                the handle, then return the child's (poked) result.
class WfDef::E2EParent :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($mode = 'execute', $arg = 'World') {
        if ($mode eq 'signal') {
            my $handle = await Temporalio::Workflow::start_child_workflow(
                'E2EChild',
                args => ['signal'],
            );
            await $handle->signal('poke', args => [$arg]);
            return await $handle->result;
        }
        return await Temporalio::Workflow::execute_child_workflow(
            'E2EChild',
            args => [$arg],
        );
    }
}

1;
