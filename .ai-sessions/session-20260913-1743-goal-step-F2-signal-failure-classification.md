# Session Summary: Route Signal-Handler Failures Through the Body's Full Classification (F2)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a one-iteration fix loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor dispatches), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F2, plan.md Section 6 Step F2 (Route Signal-Handler Failures Through the Body's Full Classification), GitHub #2 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F2, all 8 plan sub-steps)

## The Regression

I2 taught `Runner::_settle_signal` to classify a signal-handler die instead of funneling every one to workflow-task failure, but it copied only the last two branches of `_outcome_for_failure`: Temporal-failure to `FailWorkflowExecution`, everything else to a task failure.

On workflow cancel that split is wrong in a way that loses the run's real outcome.
The Runner fails parked futures with `Temporalio::Exception::Cancelled`, which isa `Temporalio::Exception`, so a parked async `:Signal` handler resumed by the cancel sweep matched the Temporal-failure branch and claimed the one-shot terminal slot with `FailWorkflowExecution` before the `:Run` body could emit `CancelWorkflowExecution`.
A run the server asked to cancel closed as Failed.
That is a regression against the pre-I2 tree, where handler dies never emitted a terminal command at all.

Continue-as-new raised from a handler and `Temporalio::Exception::Nondeterminism` were misrouted the same way: the first would have failed the execution instead of continuing the run, the second would have failed the execution instead of the task.
Settlement during `evict` had no guard at all, so an eviction teardown could emit a terminal command for a run that is already gone.

## The Fix

- A new pure `method _classify_failure ($err)` returns one of six ordered labels: `evicting`, `continue_as_new`, `cancelled` (gated on `$cancel_requested`), `nondeterminism`, `workflow_failure`, `task_failure`.
  It is shared verbatim by the body path (`_outcome_for_failure`) and by handler settlement (`_settle_signal`); the two differ only in what they DO with a label, never in how they derive one.
- A `field $evicting` latch is raised by `evict` and never lowered, so any settlement that lands during or after eviction classifies as `evicting` and emits nothing: no command, no `$current_activation_error`.
- `_repartition_after_terminal`, called at the top of `_build_completion`, restores the "state-mutating commands cannot follow the terminal command" invariant when a handler emitted the terminal command mid-sweep: it keeps the terminal command and moves it last rather than grepping to handler responses alone, which would have dropped the terminal command itself.
- `_workflow_failed_completion`'s R13 grep gained one clause so an ALREADY-emitted handler terminal command survives a later body failure; without it the body's suppressed `_emit_terminal_command` left the completion with no terminal command at all.
- The `cancelled` label DEFERS on the handler path: the handler returns and emits nothing, and the run's single `CancelWorkflowExecution` is owned by the body, emitted from `_build_completion` after the whole sweep finishes.
  sdk-python never faces the question, because `_apply_cancel_workflow` (`_workflow_instance.py:597-606`) cancels the primary task alone, so cleanup scheduled by a body that catches Cancelled survives.
  Deferring is what makes the surviving command set independent of sweep order.

## The Tests

New file `sdk/t/replay/signal_handler_classification.t` (502 lines), nine classification subtests plus a partition subtest, with fixtures `WfDef::SignalClassifier`, `WfDef::SignalTerminalPartition`, and `WfDef::SignalCancelCleanup`:

- Cancel with a parked async `:Signal` handler emits exactly one `CancelWorkflowExecution` and no `FailWorkflowExecution`.
- A cancel-resumed handler defers to the body, which keeps its post-cancel cleanup `StartTimer`.
  This is the regression the fix loop added; on the pre-fix tree it failed in BOTH hash orders, on the cancel-count assertion in one and on the dropped-cleanup assertion in the other, because body and handler both park in `%pending_timers` and whichever `keys` returned first claimed the slot.
- `continue_as_new` raised from a handler continues the run.
- A handler `Nondeterminism` fails the task under the default policy, with a sibling subtest driving `nondeterminism_as_workflow_fail => 1` through the same route to the `FailWorkflowExecution` arm.
- An `ApplicationError` from an async handler fails the execution.
- A class listed in `workflow_failure_exception_types` fails the execution from a handler; the same class UNLISTED fails only the task.
- `evict` with parked handlers emits and records nothing, probed with one activation pushed after `$harness->runner->evict`.
- Commands pushed after a handler-emitted terminal command are re-partitioned.

Full suite: 921 tests / 212 files, green. Author suite: 474 tests / 8 files, green.

## Citation Corrections

Verifying against `../sdk-python/temporalio/worker/_workflow_instance.py` while fixing the MUST-match blocks turned up two claims that were wrong in every copy:

- `self._deleting` is the FIRST check of the generic `except` clause in `_run_top_level_workflow_function`, not the first test in the function (the `_ContinueAsNewError` clause precedes it). Corrected in all four places that repeated the claim.
- Python has NO Nondeterminism branch in that function at all; it leaves non-determinism to sdk-core. Branch 4 of `_classify_failure` is Perl-only, owed to the in-language determinism guard (spec section 29.4). The comments now say so instead of citing a Python line that does not exist.
- At finalize, `workflow_is_failure_exception` in `_classify_failure`'s MUST-match block moved from `:2558` to `:2560`, the line it actually occupies.

## Housekeeping

Fourteen em-dashes on I2's added lines were replaced (Runner.pm 4, DyingAsyncSignal.pm 1, DyingSignal.pm 2, DyingSignalFailure.pm 3, signal_handler_die.t 4), one more than plan.md's NOTE estimated.
A stale `Runner.pm:3164` line anchor in DyingSignal.pm became the method name `Runner::_dispatch_signal`.

## Deviations from Plan

- Plan said: sub-step 1's eviction bullet asks for a test that "eviction with a parked handler emits no failure command and no activation error".
- Deviated: `evict()` builds no completion of its own (`WorkflowDispatcher::_handle_eviction` sends a fixed empty success and drops the runner), so the drop rule is asserted as white-box runner state through one probe activation pushed after `$harness->runner->evict`. The two eviction arms (a Cancelled teardown and a plain-die teardown) were merged into ONE subtest because the `$evicting` latch is never lowered: once fixed, the post-evict runner is inert, so the "no failure command" half is only distinguishable in combination with the "no activation error" half.
- Impact: the eviction subtest is RED on HEAD and GREEN after the fix, but it proves the terminal-slot half indirectly (the evicted runner emits nothing on any later activation) rather than by inspecting the slot directly.

- Plan said: sub-step 5, "In _build_completion, when $workflow_terminal_emitted is set, re-run the _is_handler_response_command partition".
- Deviated: implemented as a new `_repartition_after_terminal` called at the top of `_build_completion`, and it keeps the terminal command (moving it last) rather than grepping to handler responses alone, since a bare grep would drop the terminal command itself. Also extended `_workflow_failed_completion`'s R13 grep by one clause so an ALREADY-emitted handler terminal command survives a later body failure.
- Impact: one extra predicate (`_is_workflow_terminal_command`) and a two-line change in `_workflow_failed_completion` beyond the plan's wording. Both keep the "exactly one terminal command, last" invariant on every path, not just the path the new test drives.

- Plan said: sub-step 6, "thirteen em-dashes" on I2's added lines.
- Deviated: there were fourteen, matching the dispatch's count rather than plan.md's NOTE. Also replaced a stale `Runner.pm:3164` anchor in DyingSignal.pm's comment with `Runner::_dispatch_signal`.
- Impact: none beyond a slightly wider comment-only diff in the I2 fixtures.

- Plan said: sub-step 7, "the Runner POD/comments describe the shared classifier and the evicting guard".
- Deviated: while rewriting the "Completion-outcome decision table" POD section, corrected a stale claim in it that `RemoveFromCache` "never reaches the runner" (the dispatcher's fast path does call `evict`).
- Impact: none functional; the POD now matches the eviction path the `$evicting` guard lives on.

## The Fix Loop

Two validator iterations: block at 1, clean at 2.

- Iteration 1 block (`temporal.cancellation.cleanup-dropped`): `_settle_signal`'s `cancelled` arm claimed the one-shot terminal slot MID-SWEEP. `_apply_cancel_workflow` cancels `%pending_timers` third of eight sweeps, so a parked handler resumed and emitted `CancelWorkflowExecution` before the child, nexus, external, and conditions sweeps ran and before the `:Run` body unwound. A body that catches Cancelled and schedules post-cancel cleanup (spec R8, the `PostCancelTimer` contract) had its cleanup `StartTimer` dropped by `_repartition_after_terminal` and its later `CompleteWorkflowExecution` suppressed. Fixed by making the arm defer; the classifier stayed shared and untouched, only the handler's action for that one label changed.
- Iteration 1 warn (`temporal.nondeterminism.policy-coverage`): the handler Nondeterminism subtest covered only the default task-failure policy. Added the `nondeterminism_as_workflow_fail => 1` sibling.
- Iteration 1 info (`docs.must-match-citation`): the `$evicting` comment's `self._deleting` claim. Corrected in all four copies rather than one, which surfaced the missing-Nondeterminism-branch error as well.
- Iteration 2: clean, with one info-level citation line-number fix applied at finalize.

## Key Actions

- Verified the `_run_top_level_workflow_function` branch order and line numbers against `../sdk-python/temporalio/worker/_workflow_instance.py` and cited them in the Runner's MUST-match blocks.
- Ran the full unit/replay/integration suite and the author suite at finalize; both green.
- Scanned the added lines and the four new files for dashes and banned vocabulary before committing; clean.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Mode: finalize dispatch for F2 | Applied the iter-2 citation fix, ran the dash and banned-word scans, ran both suites, wrote this summary, extended lessons.md, generated the commit message, committed, pushed | Converged, one signed commit pushed to issue-closeout |

## Efficiency Insights

**What went well:**
- Extracting the classifier as a PURE method returning a label, with the two callers owning their own actions, is what let the fix loop change the handler's cancel behavior without touching classification at all. A classifier that also emitted would have forced a much wider iteration-1 diff.
- The iteration-1 RED was designed to fail in BOTH `keys %pending_timers` orders, so the order-dependence was proven rather than asserted.

**What could improve:**
- The implement pass assumed "share the classifier" implied "share the emission". Reading spec F2's own problem statement more carefully (it names the BODY as the intended emitter of the cancel command) would have caught the deferral requirement before the validator did.

**Course corrections:**
- Iteration 1 flipped the handler's `cancelled` arm from emit to defer. The spec requirement (one ordered classifier consumed by both paths) is still met; only the action changed.

## Process Improvements

- When a fix touches a MUST-match citation block that is duplicated across call sites, grep for the other copies in the same pass. Fixing one and leaving three stale is worse than the original finding.
- A regression test for order-dependent behavior should assert on the union of outcomes across both orders, or force each order explicitly, rather than passing by accident on whichever order the run happened to take.

## Observations

- `%pending_timers` is a plain hash, so any behavior that depends on which parked future resumes first is nondeterministic between runs. The cleanup-timer test was the first in this repo to make that dependence visible; a test that only checked the cancel COUNT would have been flaky rather than failing.
- The one-shot terminal slot is the scarce resource in the Runner, and every new emission site is a potential claimant. The `$evicting` latch and the handler's deferral are both narrowings of who is allowed to claim it.

## Suggested Skills for Next Session

- None specific; the next step (F3, draining a dead poll loop) should consult todo.md and spec.md directly for its own scope.
