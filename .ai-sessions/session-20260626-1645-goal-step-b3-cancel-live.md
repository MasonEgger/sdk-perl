# Session Summary: B3 C-CANCEL-LIVE - throwable Cancelled + clean cancel-mid-update (#5, #8)

**Date**: 2026-06-26
**Duration**: ~45 minutes
**Conversation Turns**: 1 (autonomous step-executor dispatch)
**Estimated Cost**: ~$3.00
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: live-hardening of sdk-perl bugs from samples; B3 cluster
  C-CANCEL-LIVE (#5, #8) - a never-true wait_condition cancel + a client cancel
  mid-:Update must end Cancelled via CancelWorkflowExecution, not a raw-cancel
  hang
- **Mode**: step
- **Outcome**: converged (B3.1-B3.4 checked off, full suite green)
- **Turn count**: 1
- **Subagent dispatches**: 1 (this dispatch)
- **Steps completed**: 4 of 4 (B3.1, B3.2, B3.3, B3.4)

## Key Actions

- Read ROOT-CAUSE-MAP.md (#5/#8 share the cancel-routing family), plan Step B3,
  the prior cancel lesson (Future SUBCLASS whose cancel FAILS with Cancelled),
  and the Runner.pm cancel surface. Confirmed the root: `wait_condition`
  (Runner.pm:1324) created a PLAIN `Temporalio::Workflow::Future`, unlike timers
  (`_TimerFuture`) and activities (`_ActivityFuture`) which subclass with a
  cancel-to-Cancelled override; and `_apply_cancel_workflow` never cancelled the
  `@conditions` futures - it only did the native `$main_run_future->cancel`
  fallback, which surfaces a bare "was cancelled" string.
- RED: built two SUBPROCESS-GUARDED live repros plus a reusable guard. The bug's
  failure mode is a HANG (#8 ~183s today), so a naive in-process repro would
  wedge prove. `t/lib/SubprocessGuard.pm` forks a child that runs the whole
  worker+cancel scenario (creating the runtime INSIDE the child - fork-before-
  threads safety), `POSIX::setsid` so the parent can `kill -$pid` the whole
  process group (including the dev-server CLI sdk-core spawns) on a hard ~30s
  timeout overrun, and `POSIX::_exit` so no Test2/END handler fires in the fork.
  `repro_cancel_live.t` (#5, fixture `WfDef::NeverCondition`) and
  `repro_cancel_mid_update.t` (#8, fixture `WfDef::UpdateParker` +
  `start_update(wait_for_stage => 'accepted')` to park the handler mid-flight).
  Both FAILED first for the documented reason: the raw-cancel surfaced
  `Workflow::Future=HASH(...) was cancelled at Runner.pm line 2714`
  (`($main_run_future->result)[0]` on a NATIVELY-cancelled future dies), the
  workflow task failed forever, `$handle->result` never resolved, and the child
  tripped the 30s guard (34s wall each).
- GREEN (one change, three edits): added `_ConditionFuture` (mirrors
  `_TimerFuture`: `cancel` runs the stored on_cancel then `->fail(Cancelled)`);
  `wait_condition` now builds a `_ConditionFuture` whose on_cancel drops the
  racing wait-timeout timer; `_apply_cancel_workflow` iterates a SNAPSHOT of
  `@conditions` and cancels each pending future BEFORE the `$main_run_future`
  fallback. The body's parked `await wait_condition` now raises a throwable
  Cancelled -> escapes :Run -> main_run_future FAILS Cancelled -> the existing
  outcome table emits CancelWorkflowExecution (gated on cancel_requested). For
  #8 the in-flight update handler's own parked condition is in the same
  `@conditions` sweep, so it settles cleanly (`_settle_update` routes Cancelled,
  a Temporal exception, to an update rejection) while the body cancels.
- REFACTOR: comments in all three edit sites cite #5/#8 and state the unified
  throwable-Cancelled contract. Audited the other awaits - timer/activity/local-
  activity/child/nexus already raise throwable Cancelled on cancel; condition was
  the lone gap; update/signal handlers inherit it by awaiting one of those.
- Verify: both repros now PASS un-gated (3-4s each, vs the 34s pre-fix hang).
  Re-ran the B1 (`repro_check_conditions.t`) and B2 (`repro_cancel_commands.t`,
  `repro_wait_any_race.t`) replay repros - all green (cross-cluster regression
  clean). Full `prove -lj4 t` green: 91 files, 528 tests, exit 0.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute B3 cluster (RED/GREEN/REFACTOR/Verify) in one commit | Reproduce-first TDD on the runner's cancel routing via subprocess-guarded live integration tests | Both repros fail-then-pass; B1+B2 repros still green; full suite exit 0; B3.1-B3.4 checked off |

## Efficiency Insights

**What went well:**
- The prior lesson (Future SUBCLASS overriding cancel to FAIL Cancelled) pointed
  straight at the root - the only missing piece was that `wait_condition` was the
  one awaitable still using a plain Future. The fix mirrored `_TimerFuture`
  verbatim, no new design.
- The subprocess guard separated the HANG failure mode from the assertion
  cleanly: RED is "child trips the 30s timeout", GREEN is "child exits 0 in
  3-4s", and the parent prove run is never at risk of wedging.

**What could improve:**
- ROOT-CAUSE-MAP.md listed the B1 repro at `t/unit/repro_check_conditions.t`; it
  is actually at `t/replay/`. A wrong-path prove invocation cost one round trip.
  The repros are at `t/replay/` and `t/integration/`, never `t/unit/`.

## Process Improvements

- For a live bug whose failure mode is a HANG (not a wrong value), the
  subprocess-guard-with-process-group-kill pattern is the right tool: fork a
  child that runs the whole scenario and exits 0 only on a verified-clean
  outcome, reap it under a hard timeout in the parent, and TERM/KILL the child's
  process group on overrun so the dev-server CLI is reaped too. B4-B6 are all
  flagged SUBPROCESS-GUARDED and should reuse `t/lib/SubprocessGuard.pm`.

## Observations

- The connect-race dev-server flake (lessons 2026-06-25) recurred ONCE on the
  first full-suite run (tuner.t, "Connection failed ... ConnectionRefused"),
  passed in isolation, and the suite was clean on the immediate re-run. tuner.t
  exercises no cancel path, so it could not be a regression. Confirming a flake
  in isolation before re-running the whole suite is the right discriminator.
- #5 and #8 shared exactly one root and one fix (the throwable-Cancelled
  condition future + the `@conditions` cancel sweep), as ROOT-CAUSE-MAP.md
  predicted. The B1 and B2 Runner.pm changes did not perturb the new path.

## Suggested Skills for Next Session

- None new for B4 (C-FD, #1/#2): it is a CLOEXEC fix in Core/Callback.pm (Perl-
  side per the B0 triage correction, likely no shim rebuild) plus a fork-pool FD
  sweep, and reuses `t/lib/SubprocessGuard.pm` for the subprocess-guarded live
  repros. Budget for the signal-fd lifecycle, not new toolchain.
