# ABOUTME: Fixture workflow that branches on Temporalio::Workflow::patched to
# ABOUTME: drive the NotifyHasPatch / SetPatchMarker test in determinism.t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run checks a patch id and returns a branch name reflecting the answer. It
# calls patched() TWICE with the same id to exercise memoization (the second
# call must return the same answer without emitting a second SetPatchMarker).
class WfDef::Patcher :isa(Temporalio::Workflow::Definition) {
    async method run :Run ($patch_id = 'my-change') {
        my $first  = Temporalio::Workflow::patched($patch_id) ? 1 : 0;
        my $second = Temporalio::Workflow::patched($patch_id) ? 1 : 0;
        return { first => $first, second => $second };
    }
}

1;
