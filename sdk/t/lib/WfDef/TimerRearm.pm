# ABOUTME: Fixture for bug #4 (B1 C-COND, same family as #3): arm a long timer on
# ABOUTME: a wait_condition, an :Update wakes the predicate, then the continuation
# ABOUTME: re-arms a short timer on a fresh wait_condition registered mid-pass.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future::AsyncAwait;
use Temporalio::Workflow;
use Temporalio::Workflow::Definition;

# The :Run parks on $woken racing a LONG (100s) timer. A `wake` :Update sets
# $woken true; _check_conditions resolves that wait, cancels the long timer, and
# runs the continuation SYNCHRONOUSLY, which re-arms a SHORT (5s) timer on a
# fresh wait_condition over $second — registered DURING the same pass. A later
# `advance` :Update must wake that re-armed condition and let the body return.
# Bug #4 (the timer-re-arm wedge) dropped the re-registered condition, so the
# re-armed wait never woke and the workflow wedged.
class WfDef::TimerRearm :isa(Temporalio::Workflow::Definition) {
    field $woken  = 0;
    field $second = 0;

    async method run :Run () {
        await Temporalio::Workflow::wait_condition(sub { $woken }, timeout => 100);
        await Temporalio::Workflow::wait_condition(sub { $second }, timeout => 5);
        return 'rearmed';
    }

    method wake :Update('wake')       (@) { $woken  = 1; return 'woke'; }
    method advance :Update('advance') (@) { $second = 1; return 'advanced'; }
}

1;
