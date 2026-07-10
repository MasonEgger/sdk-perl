# ABOUTME: Fixture workflow that executes one Nexus operation via
# ABOUTME: execute_operation and returns its result — drives the start->result
# ABOUTME: round trip (T-nexus-1..6) in the nexus replay test.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run executes a single Nexus operation and returns its result. The first
# activation (InitializeWorkflow) creates the NexusClient and parks the body on
# execute_operation, emitting one ScheduleNexusOperation command; a
# ResolveNexusOperationStart resumes to the result await; a ResolveNexusOperation
# then resolves the body, which returns the result. A failed/timed-out/cancelled
# operation surfaces as Temporalio::Exception::NexusOperation at the await site
# and bubbles out of :Run.
class WfDef::NexusCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = 'world') {
        my $nc = Temporalio::Workflow::create_nexus_client(
            endpoint => 'my-endpoint',
            service  => 'my-service',
        );
        my $result = await $nc->execute_operation('say-hello', $name);
        return $result;
    }
}

1;
