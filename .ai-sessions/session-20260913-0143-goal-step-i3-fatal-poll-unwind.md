# Session Summary: Unwind Worker::run on a Fatal Poll-Loop Death (I3)

**Date**: 2026-09-13
**Duration**: single dispatch (finalize-only; implement/validate ran in prior dispatches)
**Conversation Turns**: n/a (autonomous `/bpe:goal` dispatch)
**Estimated Cost**: n/a
**Model**: claude-sonnet-5

## Goal Context

- **Condition**: land I3 (GitHub issue #3): unwind `Worker::run` on a fatal poll-loop death instead of blocking on a healthy sibling loop indefinitely.
- **Mode**: step
- **Outcome**: converged (this step)
- **Turn count**: n/a
- **Subagent dispatches**: implement, validate (iter 1, clean), finalize (this dispatch)
- **Steps completed**: 1 (Section 1, Step I3)

## Key Actions

- Replaced `Worker::run`'s `Future->wait_all` gather over the activity/workflow/Nexus poll loops with a new `_await_loops_then_drain` combinator: a first-failure race that still waits for every loop on the clean path.
- On the fatal path, `run()` now calls `_initiate_shutdown_once` and re-awaits the survivors (`Future->wait_all(@loops)`) before `_finalize_and_free`, mirroring the ordering in `../sdk-python worker/_worker.py` (`asyncio.wait(..., return_when=FIRST_EXCEPTION)` at :812-813, `on_fatal_error` at :822-825, drain at :841, finalize at :857).
- Added `sdk/t/unit/fatal_poll_unwind.t`: a bounded, synthetic-Future unit guard proving the race resolves on first failure and still drains all loops on the clean path.
- Added `sdk/t/integration/fatal_poll_unwind.t`: a `SubprocessGuard`-timed live repro against a real worker and dev server.
- Fixed a citation drift (validator review housekeeping, non-code): `../sdk-python worker/_worker.py:813` corrected to `:812` in `sdk/t/unit/fatal_poll_unwind.t`, `sdk/t/integration/fatal_poll_unwind.t`, and `todo.md`'s Step I3 item 2 (line 812 is the `asyncio.wait(...)` call itself; :813 is the following `try:`). `Worker.pm`'s own comments already cited the correct `:812-813` range and were left untouched.
- Full suite green: `prove -lj4 t` (200 files, 866 tests) and `prove -lj4 xt` (8 files, 463 tests).
- Validator ran once (iter 1) against this diff and returned clean with no findings.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator finalize dispatch for Step I3 | Applied citation housekeeping, ran both test suites, wrote this summary, generated commit message, committed and pushed | Single clean commit, pushed |

## Efficiency Insights

**What went well:**
- The prior implement pass had already validated cleanly (iter 1), so this dispatch was pure commit-transaction work: no code logic changes, just two comment/doc citation fixes plus the session/commit bookkeeping.

**What could improve:**
- Nothing notable for this narrow finalize dispatch.

**Course corrections:**
- None.

## Process Improvements

- None new; the finalize-only dispatch flow (implement validated separately) worked as designed.

## Observations

- The plan's originally suggested fault-injection technique (reusing R94's `worker_on_fatal_error.t` sentinel-to-failure approach) turned out not to reproduce this bug at all, because `worker_initiate_shutdown` settles every poll kind at once; see Deviations from Plan below for the substitute technique the implement pass used instead.

## Suggested Skills for Next Session

- None specific; the next todo.md item (Step I1, evicted async `:Update` parked on `wait_condition`) is again Worker/Workflow-runner internals, same skill surface already in use.

## Deviations from Plan

- Plan said: reuse the R94 `on_fatal_error` test's sentinel-to-failure technique for the new subprocess-guarded integration test (`sdk/t/integration/fatal_poll_unwind.t`).
- Deviated: empirically verified (by running the candidate test against both the pre-fix and post-fix `Worker.pm`) that R94's technique does not reproduce the I3 hang at all. `worker_initiate_shutdown` is worker-wide, so calling `$worker->shutdown` up front (R94's own setup) flips the ShutDown sentinel for every poll kind at once; both loops always settle together regardless of whether `run()` uses `wait_all` or the new first-failure race, so a test built that way passes even against the unpatched code (not RED). Used a different, still-organic technique instead: wrap `_poll_activity_task` to fire the REAL underlying FFI poll (so core's activity-poller bookkeeping is properly started) but never await it, and hand the caller an immediately-failed Future instead. This reproduces a genuine "one loop dies fatally while a real, live workflow poll keeps blocking with no work and no shutdown requested" hang against the old code (confirmed RED via `git stash` on `Worker.pm` alone), and settles in about 2 seconds against the fixed code.
- Also discovered along the way: fully REPLACING `_poll_activity_task` (never issuing the real FFI call at all, not even fire-and-forget) causes an unrelated deadlock in `_finalize_and_free`/core's `at_task_mgr.shutdown()` even under the FIXED code, because core's activity-poller bookkeeping is apparently never started server-side if the SDK never issues a single real poll call for that kind. The fire-and-forget variant (issue the real call, discard the result) avoids this because core still sees a poll issued.
- Impact: the integration test's fatal-injection mechanism differs from what the plan's NOTE literally named, but the acceptance criteria (RED pre-fix, GREEN post-fix, run() returns within a bound, finalize does not deadlock) are all met and verified against both code states.
