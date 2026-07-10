# ABOUTME: Fixture workflow for R17 (finding L7): an async :Update handler that
# ABOUTME: parks on a plain (untracked) Temporalio::Workflow::Future, so evict's
# ABOUTME: %in_progress_handlers sweep NATIVELY cancels the handler future and
# ABOUTME: _settle_update must survive the cancelled state (the L7 croak).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;
use Temporalio::Workflow::Future ();

# The R17 repro body, the update-handler analog of WfDef::PlainFutureParker
# (R9). Future::AsyncAwait clones an async method's future from the FIRST
# awaited future, so parking on a plain Temporalio::Workflow::Future (native
# Future cancel semantics) makes the tracked handler future natively
# cancellable: evict's sweep ->cancel puts it in the CANCELLED state, the one
# _settle_update croaked on. (A wait_condition park is a DIFFERENT shape: the
# _ConditionFuture cancel override FAILS the cloned handler future with a
# throwable Cancelled, taking _settle_update's rejected branch instead.)
class WfDef::PlainFutureUpdater :isa(Temporalio::Workflow::Definition) {
    async method run :Run('PlainFutureUpdater') () {
        await Temporalio::Workflow::Future->new;
        return 'never';
    }

    async method park :Update('park') () {
        await Temporalio::Workflow::Future->new;
        return 'update-done';
    }
}

1;
