# ABOUTME: Fixture workflow — a :Run method NOT named "run" defaults type to the method name.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::Plain :isa(Temporalio::Workflow::Definition) {
    async method execute :Run ($x) { return "plain:$x" }
}

1;
