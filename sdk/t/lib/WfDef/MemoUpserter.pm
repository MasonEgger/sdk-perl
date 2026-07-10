# ABOUTME: Fixture workflow that upserts/removes memo on each `memo` signal then
# ABOUTME: completes on `done` — drives upsert.t ModifyWorkflowProperties cases.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run waits for `done`. Each `set` signal upserts {reason => <value>}; each
# `remove` signal upserts {stale => undef} (a removal). This drives memo
# set/delete so info->{memo} can be read back between activations (T-upsert-5/6).
class WfDef::MemoUpserter :isa(Temporalio::Workflow::Definition) {
    field $done = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $done });
        return 'ok';
    }

    method set :Signal('set') ($value) {
        Temporalio::Workflow::upsert_memo({ reason => $value });
        return;
    }

    method remove :Signal('remove') () {
        Temporalio::Workflow::upsert_memo({ stale => undef });
        return;
    }

    method finish :Signal('done') () {
        $done = 1;
        return;
    }
}

1;
