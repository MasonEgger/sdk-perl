# Session Summary: R18+R19 Pool Fork-Channel Live Heartbeat Relay and Cancel Delivery

**Date**: 2026-07-08
**Duration**: ~35 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-medium (three RED test files incl. one live dev-server run, one full-suite run, one xt run, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (step complete, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R18+R19, four sub-items)

## Key Actions

- RED (three files, each verified failing for its documented finding before GREEN):
  `sdk/t/unit/pool-live-heartbeat.t` asserts the parent observes a pooled activity's heartbeat while the body is still blocked (pre-fix: 15s window expired with nothing relayed, finding L13).
  `sdk/t/unit/pool-live-cancel.t` drives the REAL dispatcher: start a pooled spinner, deliver a Cancel activity task mid-body, require a CANCELLED completion (pre-fix: the child never saw the cancel, spun to its deadline, and the completion came back COMPLETED, finding L15); a second subtest pins the new pool-level `invoke(..., cancellation => ...)` surface and that BOTH in-child surfaces (is_cancelled and the cancellation future) flip.
  `sdk/t/integration/pool-heartbeat-timeout.t` (skip_all offline) + fixture `sdk/t/lib/WfDef/HeartbeatTimeoutCaller.pm`: a compliant ~5s sync activity heartbeating every 0.5s under a 2s heartbeat_timeout and maximum_attempts 1 must complete; pre-fix it failed live with "activity Heartbeat timeout".
- GREEN + REFACTOR (one motion, the consolidated fork-protocol shape):
  `Activity/Pool.pm` gained the R18/R19 control channel: a per-pool UNIX listener whose path rides the R4 `%channel`; each forked child `connect()`s back from `init_code`, giving one duplex stream per child. Both directions share one length-prefixed Storable frame codec (`_pack_frame`/`_take_frame`) and one frame vocabulary (start/hb/end up, cancel down). Heartbeats stream up as the body records them and the parent relays each to the FFI heartbeat immediately; `cancel_invocation` (plus the `cancellation` option on `invoke`) forwards a post-dispatch cancel down, with a pending-park for a cancel that races ahead of the child's start frame. Collect-and-return remains the degraded fallback when the child's connect fails.
  `Activity/ChildCancellation.pm` gained an optional `poll` hook consulted by every `is_cancelled` (and instantiation-time by `cancelled()`), so the pre-R19 one-shot boolean became a live token.
  `Worker/ActivityDispatcher.pm` `_run_in_pool` now passes the parent-side cancellation into `$pool->invoke` (the finding-L15 site).
  Comments cite L13/L15, the ChildManager fd-sweep rationale, and Python parity (sync activities heartbeat live and observe a post-dispatch cancelled_event, sdk-python worker/_activity.py).
- Test-only collateral: `t/unit/activity_pool.t`'s FakePool widened to `invoke ($inv, %opts)` for the new option.
- Verify: all three RED files GREEN (unit cancel test dropped 18s -> 2s); neighboring pool/activity tests green; full `prove -lj4 t` green (114 files, 583 tests); `prove -lj4 xt` green (314 tests). Not shim-touching, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R18+R19 | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Reading `IO::Async::Internals::ChildManager::_spawn_in_child` BEFORE designing the channel settled the whole approach in one pass: the child fd sweep closes everything not keep-listed, so the only reliable live link is a socket the child opens itself after the sweep (listener + init_code connect).
- The R4 per-instance `%channel` absorbed the new state (control path parent-side, control socket child-side) with zero new globals; R5's error frames were untouched.

**What could improve:**
- The pre-fix RED demonstration of the cancel test costs ~18s of spin (bounded deadline); unavoidable for a faithful repro of "cancel never arrives".

**Course corrections:**
- The 2026-06-13 lesson said a live child->parent side channel "does not work" and prescribed collect-and-return; this step falsified the generalization (the pipe failure was the fd sweep, not an impossibility) and the lesson was refined in place.

## Observations

- SIGPIPE is already ignored process-wide (IO::Async loop), but both frame writers still `local $SIG{PIPE} = 'IGNORE'` defensively around syswrite loops.
- Later-forked children inherit nothing extra: the same ChildManager sweep that motivated the design also closes the listener and any sibling connection fds in each new child, which shrinks what R30 (close inherited gRPC descriptors) has to prove.
- The next step, R30, forks pool children and asserts over /proc/self/fd; the control-channel fds added here are exactly the "keep only the pool channel fds" whitelist R30's sweep must respect.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: the next step (R30, close inherited gRPC descriptors in pool children) continues the same fork-pool/worker architecture work with reference-SDK parity checks.
