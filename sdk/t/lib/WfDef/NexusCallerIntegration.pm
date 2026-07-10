# ABOUTME: Fixture workflow for the Nexus handler integration test (T-nexus-10):
# ABOUTME: executes the test-service say-hello sync operation and returns its result.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run takes the Nexus endpoint name (the integration test passes the
# operator-registered endpoint) and executes the NexusDef::Handler 'say-hello'
# sync operation on the 'test-service' service, returning "Hello, world!".
class WfDef::NexusCallerIntegration :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($endpoint, $name = 'world') {
        my $nc = Temporalio::Workflow::create_nexus_client(
            endpoint => $endpoint,
            service  => 'test-service',
        );
        return await $nc->execute_operation('say-hello', $name);
    }
}

1;
