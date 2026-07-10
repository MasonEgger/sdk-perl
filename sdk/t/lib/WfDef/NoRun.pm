# ABOUTME: Fixture workflow — a Definition subclass with no :Run method (invalid).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow::Definition;

class WfDef::NoRun :isa(Temporalio::Workflow::Definition) {
    method ping :Query ($) { return 'pong' }
}

1;
