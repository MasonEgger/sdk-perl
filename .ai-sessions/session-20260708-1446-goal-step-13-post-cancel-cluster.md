# Session Summary: R8-R10 Post-Cancel Corruption Cluster

**Date**: 2026-07-08
**Duration**: ~45 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: moderate (three reproduce-first replay files, four WfDef fixtures, one Runner sweep rewrite, one unmasked nexus fix, two full-suite runs, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all six R8-R10 boxes complete, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (the clustered step R8-R10, findings R4/R4b/R4c)

## Key Actions

- The verify-45/cancel-core scratchpad the plan referenced is gone, so the three repros were rebuilt from the spec's defect descriptions on the existing WorkflowReplay harness pattern; the RED runs then confirmed every predicted death signature exactly.
- RED (R4, `t/replay/repro_post_cancel_cleanup.t` + `WfDef/PostCancelCleanup.pm`): body parks on a Main activity, catches the whole-workflow Cancelled, awaits a Cleanup activity, in catch-and-complete and catch-and-propagate shapes.
Pre-fix the cancel activation carried ScheduleActivity AND CancelWorkflowExecution in one completion, and the cleanup resolution died "is already failed and cannot be ->done" (the ->fail'ed twin in the propagate shape).
- RED (R4b, `t/replay/repro_cancel_plain_future.t` + `WfDef/PlainFutureParker.pm`): body parked on an untracked `Temporalio::Workflow::Future`; the cancel activation died in `_build_completion`'s `->result` ("was cancelled" at Runner.pm:2874), no completion produced.
- RED (R4c, `t/replay/repro_cancel_ext_signal.t` + `WfDef/ExtSignalWait.pm` / `WfDef/ExtCancelWait.pm`): bodies parked on the external-signal and external-cancel acknowledgement Futures died with the same :2874 croak because neither map was swept.
- Root-cause insight that explains the R4-vs-R4b death split: Future::AsyncAwait builds the async sub's return future by AWAIT_CLONE of the FIRST awaited future, so the main run future takes that future's CLASS.
A body whose first await is an `_ActivityFuture` gives the fallback a subclass whose ->cancel FAILS the clone (hookless), leaving the real pending activity registered; a plain-Future first await gives a natively-cancellable clone that later croaks in `->result`.
- GREEN in `Workflow/Runner.pm`: (R10) sweep `%pending_external_signals` and `%pending_external_cancels` in `_apply_cancel_workflow`, failing each pending Future with Cancelled and leaving the seq mapped so a late Resolve* drops via the is_ready guard; (R8) guard the main-run-future fallback behind a new `_live_pending_futures` check, since post-sweep any live tracked Future is new post-cancel cleanup work; (R9) discriminate `is_cancelled` in `_build_completion` before the success branch and route it through `_outcome_for_failure` as a Cancelled failure.
- REFACTOR: `_apply_cancel_workflow` now sweeps every pending map from ONE `@sweeps` list (LA-backoff, activities, timers, children, nexus, external signals, external cancels, conditions), with EVERY snapshot taken before any sweep runs, so cleanup work a woken catch block schedules into ANY map survives the remaining sweeps; comments cite R4/R4b/R4c and the deliver-cancellation-then-continue mechanism.
- The upfront snapshots unmasked a latent defect the old late-`keys` evaluation hid: the nexus pre-scheduled-cancel branch (T-nexus-8) only called `$handle->cancel`, which honours wait_* types and stays parked; it previously "worked" because the nexus sweep re-read the map keys after the body resumed and force-cancelled the new handle.
Fixed the branch to force-report (emit the cancel command, de-register, fail both awaits Cancelled), which is finding R3/R51's "the emergent fallback the comment gestured at is itself defective" made concrete.
- Verify: repros green, cancel-adjacent replay files green, full `prove -lj4 t` green (129 files, 610 tests), `prove -lj4 xt` green (314 tests). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for the clustered step R8-R10 (six boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Tracing the exact pre-fix mechanism (AWAIT_CLONE class capture, hookless clone fail, `->result` croak line) before writing the repros meant every RED failed for the predicted reason on the first run, and the GREEN was three surgical edits.
- Running the full suite between GREEN and REFACTOR isolated the nexus T-nexus-8 break to the refactor's snapshot change immediately.

**What could improve:**
- The plan pointed at a scratchpad (`verify-45/cancel-core/`) that no longer exists; plans should either commit probe templates or describe them fully, since the adaptation source can vanish between audit and remediation.

**Course corrections:**
- The unified-sweep refactor broke `t/replay/nexus.t` T-nexus-8; rather than reverting to late snapshots, the pre-scheduled-cancel branch was fixed to do what its comment already claimed, keeping both the R8 contract and the nexus contract.

## Process Improvements

- When a refactor replaces late `keys %hash` evaluation with upfront snapshots, grep for behavior that depended on re-reading the map after continuations ran; a passing test can be load-bearing on accidental iteration timing.

## Observations

- The R51 comment-rewrite step (queued behind this cluster) now has a second concrete input: the nexus arm at the pre-scheduled-cancel site was changed here and its comment describes the force-report mechanism; R51 should reconcile the :1188-1193 header comment with it.
- R40's remaining post-cancel arms (child, timer, local activity) should pass with no product code: the upfront-snapshot sweep protects cleanup work in every map, not just activities.

## Suggested Skills for Next Session

- None beyond the standard BPE flow; the next step (R11, always send a completion for a failed activation) is Perl-only work in Worker/WorkflowDispatcher.pm and Worker/PollLoop.pm with a subprocess-guarded integration repro (reuse `t/lib/SubprocessGuard.pm` per lessons.md).
