# ABOUTME: Fixture workflow that upserts a memo with an unencodable value —
# ABOUTME: drives the conversion-failure-before-any-command path (T-upsert-8).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# :Run upserts a memo whose value is a coderef (the default payload converter
# cannot encode it). The conversion raises BEFORE any ModifyWorkflowProperties
# command is buffered, so the activation fails with no partial command.
class WfDef::BadMemoUpserter :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        Temporalio::Workflow::upsert_memo({ bad => sub { 1 } });
        return 'unreached';
    }
}

1;
