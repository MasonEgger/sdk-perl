# ABOUTME: Fixture Nexus service for the B13 (#11) live round-trip: a real
# ABOUTME: :WorkflowRunOperation that starts a backing workflow through the
# ABOUTME: operation context's client. The op's async completion callback (wired
# ABOUTME: by WorkflowRunOperationContext::start_workflow) is what lets the
# ABOUTME: caller's Nexus operation resolve with the backing workflow's result.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Nexus::Definition;

class NexusDef::WorkflowRunHandler :isa(Temporalio::Nexus::Definition) {
    method svc :NexusService('test-service') ($) { }

    # A workflow-run operation: start the backing workflow through the context's
    # client (on the worker's own task queue) and return the resulting Nexus
    # WorkflowHandle. The handle's token becomes the async operation token; the
    # async completion callback attached to the start makes the server deliver the
    # backing workflow's result to the caller on completion (B13 #11).
    async method run_greeting :WorkflowRunOperation('run-greeting') ($ctx, $name) {
        return await $ctx->start_workflow(
            'NexusBackingWorkflow', [$name],
            id         => "b13-backing-$name-" . int(rand(1_000_000_000)),
            task_queue => $ctx->info->task_queue,
        );
    }
}

1;
