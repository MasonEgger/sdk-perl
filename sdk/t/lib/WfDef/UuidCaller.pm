# ABOUTME: Fixture workflow that calls Temporalio::Workflow::uuid4() twice in
# ABOUTME: its :Run and returns both values, for the R77 determinism replay test.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run draws two deterministic v4 UUIDs. Because uuid4 pulls from the same
# ISAAC RNG as Temporalio::Workflow::random (seeded from the InitializeWorkflow
# job's randomness_seed), replaying the same run must reproduce the same pair.
class WfDef::UuidCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        return {
            first  => Temporalio::Workflow::uuid4(),
            second => Temporalio::Workflow::uuid4(),
        };
    }
}

1;
