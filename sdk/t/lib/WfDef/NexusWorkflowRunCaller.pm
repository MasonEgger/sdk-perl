# ABOUTME: Fixture caller workflow for the B13 (#11) live round-trip: invokes the
# ABOUTME: test-service 'run-greeting' :WorkflowRunOperation and returns its
# ABOUTME: result. The operation is async (workflow-backed), so this await only
# ABOUTME: resolves once the server delivers the backing workflow's completion via
# ABOUTME: the Nexus async completion callback. Today (no callback) it parks.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

class WfDef::NexusWorkflowRunCaller :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($endpoint, $name = 'world') {
        my $nc = Temporalio::Workflow::create_nexus_client(
            endpoint => $endpoint,
            service  => 'test-service',
        );
        return await $nc->execute_operation('run-greeting', $name);
    }
}

1;
