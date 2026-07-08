# ABOUTME: Fixture workflow for R11 (finding R5): its :Query handler returns a
# ABOUTME: PENDING future, tripping the runner's `->result` croak on a query
# ABOUTME: activation so the failed-completion contract can be asserted.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Workflow::Future ();

# The R5 probe body (spec R11): the :Run parks on a long timer so the workflow
# stays in flight, and the 'pending' query returns a Future that never
# resolves. Queries are synchronous in effect, so the runner reads the query
# future's outcome immediately — a pending future croaks "is not yet ready"
# inside activation processing. Pre-fix that die escaped process_activation,
# the poll loop warned-and-swallowed it, and the workflow task was never
# completed (the workflow wedged until timeout, forever on each retry).
class WfDef::PendingQuery :isa(Temporalio::Workflow::Definition) {
    async method run :Run('PendingQuery') () {
        await Temporalio::Workflow::sleep(3600);
        return 'done';
    }

    method pending :Query('pending') () {
        return Temporalio::Workflow::Future->new;
    }
}

1;
