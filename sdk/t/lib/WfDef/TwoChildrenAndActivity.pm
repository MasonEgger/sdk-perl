# ABOUTME: Fixture workflow that starts two children plus one activity to prove
# ABOUTME: child workflows use a separate seq space (children get seq 1,2 while
# ABOUTME: the activity is also seq 1) — drives T-child-8.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run schedules one activity and starts two children back to back. Both
# children allocate from the CHILD seq space (1 then 2) while the activity is
# seq 1 in the ACTIVITY space — a child and an activity are both seq 1. Calling
# start_child_workflow without awaiting between the two emits BOTH
# StartChildWorkflowExecution commands on the first activation (the returned
# start Futures are awaited together afterwards). Out-of-order resolution must
# land each result on its own handle (matched by seq, not arrival order).
class WfDef::TwoChildrenAndActivity :isa(Temporalio::Workflow::Definition) {
    async method run :Run () {
        my $act = Temporalio::Workflow::start_activity(
            'AnActivity',
            start_to_close_timeout => 60,
        );
        # Kick off both children WITHOUT awaiting between them so both
        # StartChildWorkflowExecution commands land in the same activation.
        my $start1 = Temporalio::Workflow::start_child_workflow('ChildOne', id => 'c1');
        my $start2 = Temporalio::Workflow::start_child_workflow('ChildTwo', id => 'c2');
        my $h1 = await $start1;
        my $h2 = await $start2;
        my $r1 = await $h1->result;
        my $r2 = await $h2->result;
        my $ra = await $act;
        return [ $r1, $r2, $ra ];
    }
}

1;
