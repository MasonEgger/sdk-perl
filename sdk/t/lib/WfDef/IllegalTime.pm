# ABOUTME: Fixture workflow whose body calls the core `time` builtin directly,
# ABOUTME: which the determinism guard must trap as Nondeterminism (T-det-1).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run calls CORE `time` (unqualified) inside workflow context. With the
# determinism guard installed and $Runner::CURRENT set, this must throw
# Temporalio::Exception::Nondeterminism rather than return the OS clock value.
class WfDef::IllegalTime :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $t = time;
        return $t;
    }
}

1;
