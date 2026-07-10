# ABOUTME: Fixture workflow for spec R83: emits a counter via the workflow
# ABOUTME: metric meter so replay tests can assert live-emit vs replay-suppress.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run body records one counter increment with a per-call attribute. The
# replay test injects a MetricBuffer-backed meter into the harness and asserts
# the add reaches the buffer on a live activation and is suppressed while the
# activation replays (Python parity: workflow/_context.py:710's replay-safe
# meter).
class WfDef::MetricEmitter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $meter   = Temporalio::Workflow::metric_meter();
        my $counter = $meter->create_counter('wf_counter',
            description => 'R83 test counter',
            unit        => 'widgets',
        );
        $counter->add(1, { phase => 'run' });
        return 'emitted';
    }
}

1;
