# ABOUTME: Fixture activity class for T-act-2 — :Defn('Custom') name override.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Activity::Definition;

class ActDef::CustomName :isa(Temporalio::Activity::Definition) {
    async method run :Defn('Custom') ($x) {
        return $x;
    }
}

1;
