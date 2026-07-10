# ABOUTME: Fixture workflow whose body calls CORE::time (explicitly qualified),
# ABOUTME: which the guard CANNOT trap - pins the best-effort gap (T-det-7).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run calls CORE::time (explicitly CORE::-qualified). A CORE::GLOBAL::
# override only intercepts the UNqualified `time`; an explicit CORE:: call binds
# to the builtin directly and is NOT trapped. The body therefore completes
# normally - this documents the narrowed best-effort boundary (spec §29.4).
class WfDef::CoreQualified :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $t = CORE::time();
        return $t > 0 ? 'ok' : 'bad';
    }
}

1;
