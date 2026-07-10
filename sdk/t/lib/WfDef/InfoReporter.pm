# ABOUTME: Fixture workflow whose :Run returns the full Temporalio::Workflow::info()
# ABOUTME: hashref so replay tests can assert the info surface field by field (R36).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run returns info() verbatim. The runner sets
# $Temporalio::Workflow::Runner::CURRENT around the body, so the hashref
# carries the run's activation-seeded values (workflow_id, attempt, run_id,
# ...) plus the worker-injected ones (task_queue, namespace).
class WfDef::InfoReporter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        return Temporalio::Workflow::info();
    }
}

1;
