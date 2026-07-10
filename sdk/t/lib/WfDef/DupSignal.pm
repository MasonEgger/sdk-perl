# ABOUTME: Fixture workflow — two :Signal handlers with the same name; must raise Argument.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::DupSignal :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($x) { return $x }
    method one :Signal('dup') ($v) { return }
    method two :Signal('dup') ($v) { return }
}

1;
