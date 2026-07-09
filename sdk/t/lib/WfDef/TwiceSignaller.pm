# ABOUTME: Replay driver workflow (t/replay/repro_external_signal.t) — gets an external handle to a target by
# ABOUTME: id and signals it TWICE in a row, exercising the cross-workflow signal
# ABOUTME: hand-off after the first grant (#2 regression guard).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# Driven by ($target_id): get an external handle to $target_id and deliver two
# 'tick' signals back to back. Before the cross-workflow signal-fd fix the
# second delivery stalled after the first grant; this fixture asserts both land.
class WfDef::TwiceSignaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($target_id = '') {
        my $h = Temporalio::Workflow::get_external_workflow_handle($target_id);
        await $h->signal('tick', args => [1]);
        await $h->signal('tick', args => [2]);
        return 'done';
    }
}

1;
