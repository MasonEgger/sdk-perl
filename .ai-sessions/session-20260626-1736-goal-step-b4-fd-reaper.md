# Session Summary: B4 C-FD - fork-pool/dev-server child-reaper ownership at teardown (#1; #2 guard)

**Date**: 2026-06-26
**Duration**: ~50 minutes
**Conversation Turns**: 1 (autonomous step-executor dispatch)
**Estimated Cost**: ~$3.50
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: live-hardening of sdk-perl bugs from samples; B4 cluster C-FD,
  RE-SCOPED to the verified root cause of #1 (a child-reaper race at dev-server
  shutdown, NOT the disproven signal-fd CLOEXEC hypothesis), plus #2 as a
  regression guard
- **Mode**: step
- **Outcome**: converged (B4.1-B4.5 checked off, full suite green)
- **Turn count**: 1
- **Subagent dispatches**: 1 (this dispatch)
- **Steps completed**: 5 of 5 (B4.1-B4.5)

## Key Actions

- Read ROOT-CAUSE-MAP.md, plan Step B4, the B3 summary, and the relevant code:
  Activity::Pool (sync fork pool), Test::DevServer (ephemeral server shutdown),
  SubprocessGuard, and the installed IO::Async::Loop (0.805) child-watching
  internals. Confirmed the corrected root cause described in the dispatch.
- Pinned the exact mechanism in IO::Async::Loop 0.805: the first `watch_process`
  (IO::Async::Function forks a worker) installs ONE process-wide SIGCHLD handler
  whose `_reap_children` does `waitpid(-1, WNOHANG)` and reaps EVERY exited
  child. The loop only detaches it via `unwatch_process`; reaping through the
  SIGCHLD path does NOT detach it, so the handler LINGERS for the life of the
  loop. At `$server->shutdown` it reaps sdk-core's ephemeral `temporal` CLI
  subprocess before core's own `waitpid`, SEGVing core (exit 139 / signal 11).
- RED: two SUBPROCESS-GUARDED repros (reusing t/lib/SubprocessGuard.pm).
  `repro_fd_signal.t` runs a worker with a SYNC fork-pool activity
  (FunctionDefinition sync => 1, WfDef::ActivityCaller) + an ephemeral dev
  server through the FULL lifecycle including `$server->shutdown`, asserting the
  guard child exits 0. It failed first with `signal 11` exactly at
  `$server->shutdown` (one connect-race flake on the first run; re-ran and got
  the documented SEGV). `repro_external_signal.t` (new fixtures TwiceSignaller +
  TwiceCounter) signals B twice via get_external_workflow_handle; it PASSED
  unmodified, confirming #2 is already healthy on v1 (kept as a regression
  guard, no fabricated red).
- GREEN (option c, test-teardown-side): `Temporalio::Test::DevServer->shutdown`
  now suspends the lingering reaper for the core-shutdown window via a
  `_suspend_io_async_child_reaper($loop)` helper. First attempt guarded on
  "childwatches empty" and stayed red: debug showed childwatches still held one
  stopped-but-unreaped fork-pool worker at shutdown time (IO::Async::Function
  ->stop is async). Fixed by unconditionally detaching the loop's childwatch
  CHLD handler and reaping any still-watched pid ourselves (WNOHANG) to avoid a
  zombie; IO::Async lazily re-arms on the next watch_process. NO shim, NO
  Callback.pm, NO cargo/Alien rebuild. Added `use POSIX ()` and
  `use Scalar::Util ()` to DevServer.
- REFACTOR: documented the reaper-ownership contract in the DevServer helper
  (citing #1) and a cross-reference comment at the fork pool in Activity/Pool.pm
  where the reaper is installed.
- Corrected ROOT-CAUSE-MAP.md (the #1/#2 rows, the shared-root note, and the
  plan-anchor-correction section), plan.md (cluster table row, status line, and
  the whole Step B4 NOTE + procedure), and todo.md (dropped the `[SHIM]` label
  and the Callback.pm CLOEXEC anchor) to record the real root cause and that the
  fix is test-teardown-side.
- Verify: repro_fd_signal.t passes un-gated (3x stable), repro_external_signal.t
  passes, full `prove -lj4 t` green (93 files, 530 tests, exit 0), author POD
  tests green (306 tests).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute B4 (RED/GREEN/REFACTOR/Verify) re-scoped to the reaper race, one commit | Reproduce-first TDD: subprocess-guarded SEGV repro, DevServer teardown-side reaper suspension, doc corrections | repro_fd_signal.t fail-then-pass; #2 guard green; full suite exit 0; B4.1-B4.5 checked off |

## Efficiency Insights

**What went well:**
- Reading the installed IO::Async::Loop source directly (not from memory) gave
  the exact field names (`childwatches`, `childwatch_sigid`) and the precise
  linger semantics, which made the fix targeted instead of speculative.
- A one-line STDERR debug of the loop state at shutdown time immediately
  explained the first failed GREEN attempt (a still-watched fork-pool worker),
  turning a guessing loop into a single correction.

**What could improve:**
- The first GREEN guarded on "childwatches empty", assuming worker shutdown had
  already reaped the fork pool. It had not (Function->stop is async). The cheap
  debug print would have been worth adding before the first GREEN, not after.

**Course corrections:**
- Dropped the "only suspend when no children are watched" guard in favor of
  always-detach + self-reap, after the debug showed a lingering watched worker.

## Process Improvements

- When a fix pokes another library's internals (here IO::Async::Loop fields),
  inspect the INSTALLED version's source for the exact field/method names and
  lifecycle, and pin the behavior with a test, rather than coding to remembered
  internals.
- For a teardown-ordering race, instrument the actual runtime state at the race
  point (one STDERR line) before writing the fix; the state often contradicts
  the assumed teardown order.

## Observations

- The B0 triage's #1/#2 "shared signal-fd lifecycle" guess was wrong on both
  counts: #1 is a reaper race (no fd close involved) and #2 was already healthy.
  The dispatch's pre-verified root cause matched the live behavior exactly.
- The connect-race dev-server flake recurred once (first repro_fd_signal.t run,
  ConnectionRefused) and cleared on re-run, consistent with the 2026-06-25
  lessons. Re-running in isolation discriminated flake from the real SEGV.

## Suggested Skills for Next Session

- None new for B5 (C-LOCALACT, #9: `execute_local_activity` SEGV). It is a
  Perl-side Worker.pm hardcoded `enable_local_activities => 0` diagnosis (B5.2
  decides Perl-vs-shim) and reuses t/lib/SubprocessGuard.pm for the
  subprocess-guarded live repro. Budget for the local-activity enablement path,
  and be ready for the shim rebuild ritual only if B5.2 points there.
