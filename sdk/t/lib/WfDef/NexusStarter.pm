# ABOUTME: Fixture workflow that starts a Nexus operation and returns its
# ABOUTME: operation_token once started (async op) — drives the start-only path
# ABOUTME: (T-nexus-3) without awaiting the result.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run starts one Nexus operation and returns its operation_token (so the
# workflow completes on the start resolution, NOT on the result). An async start
# (ResolveNexusOperationStart{operation_token}) makes operation_token defined; a
# sync start (started_sync) leaves it undef.
class WfDef::NexusStarter :isa(Temporalio::Workflow::Definition) {
    async method run :Run {
        my $nc = Temporalio::Workflow::create_nexus_client(
            endpoint => 'my-endpoint',
            service  => 'my-service',
        );
        my $handle = await $nc->start_operation('say-hello', 'world');
        return $handle->operation_token // '<sync>';
    }
}

1;
