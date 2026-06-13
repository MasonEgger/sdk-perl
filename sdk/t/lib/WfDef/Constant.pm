# ABOUTME: Fixture workflow whose :Run returns a constant — the trivial-complete
# ABOUTME: replay case (T-wf-11): one activation -> one CompleteWorkflowExecution.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::Constant :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = undef) {
        return defined $name ? "Hello, $name!" : 'Hello!';
    }
}

1;
