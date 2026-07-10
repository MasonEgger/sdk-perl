# ABOUTME: Fixture workflow whose :Run throws WfDef::CustomError — a non-Temporal
# ABOUTME: class. Drives T-wf-15c: it fails the WORKFLOW only when its class is in
# ABOUTME: the worker's workflow_failure_exception_types; otherwise it fails the TASK.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;
use WfDef::CustomError ();

class WfDef::CustomFailer :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        WfDef::CustomError->throw(message => 'custom boom');
    }
}

1;
