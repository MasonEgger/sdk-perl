# ABOUTME: Fixture workflow for R9 (finding R4b): parks on a plain (untracked)
# ABOUTME: Temporalio::Workflow::Future that no activation job ever resolves, so a
# ABOUTME: whole-workflow cancel can only reach it via the main-run-future fallback.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Workflow::Future ();

# The R4b probe body (spec R9): the future awaited here is in NO pending map,
# so _apply_cancel_workflow's sweep never touches it and the fallback cancels
# the main run Future natively. Pre-fix, _build_completion did not discriminate
# the cancelled state and ->result croaked "was cancelled" with no completion
# produced; fixed, the cancelled run maps to CancelWorkflowExecution.
class WfDef::PlainFutureParker :isa(Temporalio::Workflow::Definition) {
    async method run :Run('PlainFutureParker') () {
        my $parked = Temporalio::Workflow::Future->new;
        await $parked;
        return 'never';
    }
}

1;
