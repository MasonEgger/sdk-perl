# ABOUTME: Fixture activity class for T-act-3 — two :Defn methods on one class.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Activity::Definition;

class ActDef::TwoDefns :isa(Temporalio::Activity::Definition) {
    async method first  :Defn ($x) { return "first:$x" }
    async method second :Defn ($x) { return "second:$x" }
}

1;
