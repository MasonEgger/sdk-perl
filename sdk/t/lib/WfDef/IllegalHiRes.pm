# ABOUTME: Fixture workflow whose body calls Time::HiRes::time, which the guard
# ABOUTME: traps via a symbol-table override (not a CORE::GLOBAL:: builtin) - T-det-5.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Time::HiRes ();
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run calls Time::HiRes::time inside workflow context. The determinism
# guard overrides Time::HiRes::{time,gettimeofday,sleep} in the symbol table, so
# in workflow context this throws Nondeterminism (T-det-5).
class WfDef::IllegalHiRes :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $t = Time::HiRes::time();
        return $t;
    }
}

1;
