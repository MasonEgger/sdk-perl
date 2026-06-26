# Session Summary: B2 C-CANCEL-CMD - de-duplicated terminal commands (#6, #7)

**Date**: 2026-06-26
**Duration**: ~30 minutes
**Conversation Turns**: 1 (autonomous step-executor dispatch)
**Estimated Cost**: ~$2.50
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: live-hardening of sdk-perl bugs from samples; B2 cluster
  C-CANCEL-CMD (bugs #6, #7) valid, de-duplicated cancel/complete commands
- **Mode**: step
- **Outcome**: converged (B2.1-B2.4 checked off, full suite green)
- **Turn count**: 1
- **Subagent dispatches**: 1 (this dispatch)
- **Steps completed**: 4 of 4 (B2.1, B2.2, B2.3, B2.4)

## Key Actions

- Read ROOT-CAUSE-MAP.md and plan.md Step B2, then the two samples that
  surfaced the bugs (cancellation/Workflow.pm, timer/Workflow.pm). Both samples
  already carry WORKAROUNDS (abandon for #6, on_ready-leave-loser-pending for
  #7), so the repros had to re-create the NATURAL approach (try_cancel, and
  Future->wait_any).
- Reproduce-first: empirically probed the runner with hand-built activations.
  The shared root is NOT a per-activation double-push; it is the absence of a
  RUN-scoped "terminal command already emitted" guard. After the :Run Future
  settles, core delivers ONE MORE activation (the ResolveActivity for the
  activity that the CancelWorkflow cancel-chain (#6) or the wait_any loser-cancel
  (#7) left pending). The outcome decision table runs every activation, so the
  still-settled :Run Future re-emitted its terminal command on that
  post-terminal activation: [..., Cancel, Cancel] for #6, [..., Complete,
  Complete] for #7. Probes confirmed the duplicate lands on a4/a3 (the
  post-terminal resolve), not within the cancel/fire activation.
- RED: added `t/lib/WfDef/TryCancelSaga.pm` (#6) and `t/lib/WfDef/WaitAnyRace.pm`
  (#7) fixtures plus `t/replay/repro_cancel_commands.t` and
  `t/replay/repro_wait_any_race.t`. Both assert on the EMITTED COMMAND LIST
  ACROSS THE WHOLE RUN (exactly one Cancel + one RequestCancelActivity for #6;
  exactly one Complete + one loser RequestCancelActivity for #7), so the
  double-terminal surfaces without the live SEGV. Confirmed both FAIL first
  (GOT 2 terminal commands vs CHECK 1).
- GREEN/REFACTOR (one change): added a run-scoped `$workflow_terminal_emitted`
  field and a centralized `_emit_terminal_command($cmd)` helper that pushes a
  terminal command at most once per run. Routed all FOUR terminal sites through
  it (complete in `_build_completion`, cancel + continue-as-new in
  `_outcome_for_failure`, fail in `_workflow_failed_completion`); comment cites
  #6/#7. The "no RequestCancel for an already-resolved seq" guard was already in
  place (`_apply_resolve_activity` deletes %pending_activities and tolerates the
  stale resolve; Future->cancel on a ready future is a no-op), so the repro
  asserts it as a regression and it passed pre- and post-fix.
- Verify: both repros pass; the seven cancellation-touching replay suites
  (completion_outcomes, activities, timers, child_workflows, local_activities,
  nexus, external_workflow) unchanged; full `prove -lj4 t` green (89 files,
  526 tests, 2 integration skips offline).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute B2 cluster (RED/GREEN/REFACTOR/Verify) in one commit | TDD on the runner's terminal-command emission, reproduce-first | Both repros fail-then-pass; full suite green; B2.1-B2.4 checked off |

## Efficiency Insights

**What went well:**
- Reproduce-first via direct runner probes was decisive. The simple CancelAwaiter
  fixture (await one activity, propagate Cancelled) does NOT reproduce #6; the
  duplicate only appears when core delivers the post-terminal ResolveActivity.
  Probing rather than guessing pinned the activation index where the second
  terminal command lands.

**What could improve:**
- First WaitAnyRace return logic used `is_ready` to pick the winner; a
  wait_any-cancelled loser IS ready, so it returned 'work-done' on the
  timer-wins path. Switched to `is_done` (matching the sample's pure
  Timer::Race::resolve_race). Reading the sample's helper first would have
  avoided the round trip.

## Process Improvements

- For a "duplicate terminal command" wedge, assert on the command list
  ACCUMULATED ACROSS ALL ACTIVATIONS (push every push_activation's commands into
  one @all), not per-activation. The duplicate is split across the
  cancel/fire activation and the later post-terminal resolve, so a
  per-activation count misses it.

## Observations

- #6 and #7 share exactly one root and one fix (the run-scoped terminal guard),
  as ROOT-CAUSE-MAP.md predicted. The B1 condition fix did not perturb the
  cancellation activation sequences (the seven existing replay suites still pass
  unchanged).
- The guard also closes a latent variant the bug report did not call out: a
  query (or any) activation arriving AFTER a normal CompleteWorkflowExecution
  would previously have re-emitted Complete. Now suppressed.

## Suggested Skills for Next Session

- None required for B3 (C-CANCEL-LIVE, #5/#8). It is a cancel-routing change in
  the same Runner.pm but uses SUBPROCESS-GUARDED live integration tests (the
  mid-update path hangs ~183s today), so budget for the live-worker harness and
  the ~30s child-timeout guard rather than new toolchain.
