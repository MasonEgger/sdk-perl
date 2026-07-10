# ABOUTME: Fixture workflow whose :Run plain-dies (a non-Temporal string death)
# ABOUTME: — drives the workflow-TASK-failure outcome (T-wf-15a): the completion
# ABOUTME: is `failed`, the workflow execution is NOT failed.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::TaskFailer :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        die "boom\n";
    }
}

1;
