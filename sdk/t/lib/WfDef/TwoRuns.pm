# ABOUTME: Fixture workflow — two :Run methods; must raise Argument at registration.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::TwoRuns :isa(Temporalio::Workflow::Definition) {
    async method run   :Run ($x) { return "a:$x" }
    async method other :Run ($x) { return "b:$x" }
}

1;
