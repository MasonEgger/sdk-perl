# ABOUTME: Fixture workflow that calls upsert with empty updates then returns —
# ABOUTME: drives the early-return (no command) path in upsert.t (T-upsert-7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run calls both verbs with empty updates (no SA updates, an empty memo
# hashref) — neither should buffer a command — then completes. The only command
# in the completion is CompleteWorkflowExecution.
class WfDef::EmptyUpserter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        Temporalio::Workflow::upsert_search_attributes();
        Temporalio::Workflow::upsert_memo({});
        return 'ok';
    }
}

1;
