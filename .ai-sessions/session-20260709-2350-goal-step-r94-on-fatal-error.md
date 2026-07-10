# Session Summary: Step R94, on_fatal_error Worker Hook

**Date**: 2026-07-09
**Duration**: ~20 minutes
**Conversation Turns**: 1 (autonomous dispatch)
**Estimated Cost**: low (single step-executor dispatch; one live probe before RED)
**Model**: claude-fable-5

## Goal Context

- **Condition**: execute todo.md step R94 (on_fatal_error worker hook invoked with the fatal error before the fatal-path shutdown, throwing hook logged and ignored, to _worker.py parity), one commit
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (R94.1 through R94.4 checked; full suite green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1

## Key Actions

- Pinned the parity target: Python accepts `on_fatal_error` (`_worker.py:134`), documents that it cannot stop the shutdown and that its exceptions are logged and ignored (`:289-291`), and awaits it right after the fatal worker-task exception is captured, before bridge `initiate_shutdown`, under a bare-except warning guard (`:822-825`).
- Probed the fatal unwind live BEFORE writing RED: poll sources that fail without ever reaching core leave `run()` hung forever in `_finalize_and_free` (core's `finalize_shutdown` awaits `workflows.shutdown()`, which needs the polls drained; the P2.2 never-run deadlock generalizes to the fatal path).
- RED: `sdk/t/integration/worker_on_fatal_error.t`, subprocess-guarded: the poll methods are wrapped record-then-delegate (R92/R93 pattern) so each delegates to the real core poll and transforms the drained ShutDown sentinel into a failure.
Initiating shutdown then turns both sentinels into poll-loop deaths whose unwind completes.
Scenario 1 asserts the hook fires with the fatal error while `run()`'s future is still pending; scenario 2 asserts a throwing hook is warned (`$SIG{__WARN__}` capture) and ignored, with the original failure propagating unmasked; edge asserts a non-coderef raises the typed Argument at construction.
Honest RED: `Worker->new` rejected the unknown `on_fatal_error` kwarg.
- GREEN: `Worker.pm` gains `field $on_fatal_error :param = undef` (coderef-validated in ADJUST), invoked in `run()` at the single post-R62 fatal-path unwind point (where the poll-loop `$error` is first known, before `_initiate_shutdown_once`/finalize), guarded by the same `{ local $@; eval { ...; 1 } or ... }` shape as the finalize site; a returned Future is awaited under the guard; a die warns `Temporalio::Worker: on_fatal_error hook died: ...` and is ignored.
- REFACTOR: already in the GREEN shape; the comment cites parity audit worker finding 3, the R62 secondary-attachment rework, and the Python invocation site. POD: constructor item + `run()` fatal-path note.
- Verify: `prove -lj4 t` green (194 files, 847 tests, live guarded scenario included); `prove -lj4 xt` green (435).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: R94, on_fatal_error worker hook | Live unwind probe, RED integration test, Worker.pm kwarg + hook invocation + POD, todo check-off | Step complete, suites green, one commit |

## Efficiency Insights

**What went well:**
- Probing the fatal unwind in a scratch script before committing to a RED design avoided baking an unfixable hang into the test; the sentinel-transform inducement came straight out of the probe.
- The R92 test file was again a drop-in template (gate, guarded child, monkeypatch pattern, cleanup ritual).

**What could improve:**
- The plan's `Worker.pm:568,589` anchors were pre-R62 and no longer point at re-raise sites; verifying anchors against the current file before coding is now routine.

**Course corrections:**
- First probe (polls failing without reaching core) hung in finalize; switched the inducement to delegate-then-transform-sentinel so core drains fully and the unwind completes.

## Process Improvements

- None.

## Observations

- Latent gap, out of R94 scope: a REAL fatal poll-loop death (one loop dying while others still poll) never returns from `run()` today. `Future->wait_all` waits for every loop, so a single-loop fatal leaves the healthy loops polling forever (shutdown is only initiated after wait_all settles), and even when all loops die the finalize deadlocks on undrained core polls. Python solves both with `FIRST_EXCEPTION` + `drain_poll_queue` (`_worker.py:813,846-848`). The R94 hook itself is correctly placed for whenever that drain lands.
- The core-side `shutdown_worker rpc errored ... ConnectionReset` WARN seen in the test output is core's own benign teardown warning (the P10.0 tolerance class), not a test failure.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R95 (real-history and multi-history replayer) pins against Python `worker/_replayer.py:110,138,166`; the 2026-07-09 replayer lesson in lessons.md maps the c-bridge replay surface.
