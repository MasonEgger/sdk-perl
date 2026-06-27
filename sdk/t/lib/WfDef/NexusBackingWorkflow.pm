# ABOUTME: Fixture workflow that BACKS a :WorkflowRunOperation (B13 #11): a
# ABOUTME: WorkflowRunHandler op starts it, and the caller's Nexus operation must
# ABOUTME: resolve with this workflow's result once it completes — which only
# ABOUTME: happens if the start carried the Nexus async completion callback.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::NexusBackingWorkflow :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($name = 'world') {
        return "Hello, $name!";
    }
}

1;
