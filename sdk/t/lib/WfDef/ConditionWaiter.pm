# ABOUTME: Fixture workflow whose :Run awaits wait_condition on a flag a :Signal
# ABOUTME: flips — drives the re-check-per-pump path in wait_condition.t (T-wf-5).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run blocks on wait_condition until the `ready` field is true, then
# returns the greeting set alongside it. A SignalWorkflow job sets both fields;
# wait_condition's predicate is re-checked after the signal is applied, so the
# awaiting :Run continuation resumes in the activation that carries the signal
# (T-wf-5: pump resumes the awaiting continuation only after the signal is
# processed).
class WfDef::ConditionWaiter :isa(Temporalio::Workflow::Definition) {
    field $ready    = 0;
    field $greeting = '';

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $ready });
        return "ready:$greeting";
    }

    method go :Signal('go') ($value) {
        $greeting = $value;
        $ready    = 1;
        return;
    }
}

1;
