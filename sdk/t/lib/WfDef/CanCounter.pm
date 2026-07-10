# ABOUTME: End-to-end fixture (P5.2): continues-as-new to ITSELF, incrementing a
# ABOUTME: counter until it reaches the target, then returns the final count. The
# ABOUTME: same workflow type and task queue carry across runs so one registered
# ABOUTME: worker drives the whole chain — exercises result(follow_runs) live
# ABOUTME: against a real WorkflowExecutionContinuedAsNew event (T-cli-result-4).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::CanCounter :isa(Temporalio::Workflow::Definition) {
    # run($count, $target): when $count >= $target return the final count;
    # otherwise continue-as-new to the SAME type (undef re-uses the current
    # workflow type) with the incremented count. No task_queue override, so the
    # new run lands on the same queue this worker is already polling — the chain
    # runs to completion under one worker.
    async method run :Run('CanCounter') ($count = 0, $target = 2) {
        if ($count >= $target) {
            return $count;
        }
        Temporalio::Workflow::continue_as_new(
            undef,
            args => [ $count + 1, $target ],
        );
        return 'unreachable';
    }
}

1;
