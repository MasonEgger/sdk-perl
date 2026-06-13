# ABOUTME: Fixture workflow — :Run('CustomWorkflow') overrides the workflow type.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::CustomRun :isa(Temporalio::Workflow::Definition) {
    async method run :Run('CustomWorkflow') ($x) { return "custom:$x" }
}

1;
