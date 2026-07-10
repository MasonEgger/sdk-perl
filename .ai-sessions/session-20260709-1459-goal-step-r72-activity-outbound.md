# Session Summary: Step R72, Add the Activity-Outbound Interceptor and Wire ActivityInbound.init

**Date**: 2026-07-09
**Duration**: ~25 minutes
**Conversation Turns**: 1 (autonomous dispatch)
**Estimated Cost**: moderate (single step-executor dispatch)
**Model**: claude-fable-5

## Goal Context

- **Condition**: execute todo.md step R72 (activity-outbound interceptor + ActivityInbound.init wiring, parity finding 2), one commit
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (R72.1 through R72.4 checked; full suite green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1

## Key Actions

- Verified the Python install mechanism first: `_activity.py:709-713` folds the inbound chain, calls `impl.init(_ActivityOutboundImpl(...))`, and the root inbound's init (`:813-818`) installs `outbound.info`/`outbound.heartbeat` onto the context.
The chain surface is `ActivityOutboundInterceptor` (`_interceptor.py:135-156`): info and heartbeat only.
- RED: `sdk/t/unit/interceptor_activity_outbound.t` with an init-wrapping interceptor fixture on the `worker_inbound_interceptor.t` dispatcher harness.
Four subtests: a delegating heartbeat override observes the details and still reaches the recorder, a swallowing override replaces the recording (nothing reaches the recorder), an info override observes the call while the real info returns through the root, and the no-interceptor base still heartbeats through.
Failed pre-wire at compile: `Temporalio::Worker::ActivityOutbound` did not exist.
- GREEN: `Worker/Interceptor.pm` gained the ActivityOutbound base (info + heartbeat delegating to next) and a `Heartbeat` input; heartbeat details ride the Input's writable `args` field (Python's `*details`), and activity info reuses the R71 `Info` input (only `_root`).
New `Worker/_RootActivityOutbound.pm` (own file, one `class :isa` per file); `_RootActivityInbound` gained the `on_init` capture field mirroring `_RootWorkflowInbound`.
`ActivityDispatcher._handle_start` builds the chain pair and hands the finished outbound to `Activity::Context`, whose `heartbeat`/`info` route through it when set (`_record_heartbeat` holds the real recording as the chain root's `_root` target).
- Documented spec §0 deviation: the fork-pool child's context has no chain, so pooled sync-activity heartbeats bypass the outbound interceptors.
Python heartbeats parent-side through the chain via `register_heartbeater(ctx.heartbeat)` (`_activity.py:857-865`); our pool relay carries already-serialized ActivityHeartbeat bytes, so there is nothing chain-shaped to intercept parent-side.
- REFACTOR: the R71 init-capture fold moved into a shared `Temporalio::Worker::Interceptor::build_chains($interceptors, $fold, $inbound_root_class, $outbound_root_class, $kind)`; `Runner::_build_interceptor_chains` now delegates to it.
Root classes are passed as names of already-loaded classes because Interceptor.pm cannot `use` the `_Root*` modules without a circular-load hazard against its own base classes.
- Author-test fixes: `xt/pod-coverage.t` %TRUSTME entry for `_RootActivityOutbound`; POD for ActivityOutbound, build_chains, and the Context `outbound` param + chain-routing note.
- Verify: `prove -lj4 t` green (169 files, 768 tests, live integration included); `prove -lj4 xt` green (418).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: R72, activity-outbound interceptor | RED unit test, ActivityOutbound base + root, init-capture wiring, Context routing, shared build_chains helper | Step complete, suites green, one commit |

## Efficiency Insights

**What went well:**
- The R71 session summary's process note ("R72 should reuse the init-capture pattern") was exactly right; `_RootActivityInbound` + `on_init` + `build_chains` dropped in with no design detours.
- Reading `_activity.py:709-713/813-818` before designing confirmed the context (not the dispatcher) is where the routing belongs, matching Python's `context.info = outbound.info` install.

**What could improve:**
- Nothing notable.

**Course corrections:**
- None.

## Process Improvements

- R73 (nexus inbound) should extend the same shared fold: `build_chains` covers the init-driven inbound+outbound pair, but nexus has no outbound side, so R73 likely wants only a fold over a handler-running root (`build_activity_inbound`'s shape) plus a new `intercept_nexus_operation` hook, not `build_chains` itself.

## Observations

- Heartbeat details riding the writable `args` Input field keeps spec §27.1's "only args/headers writable" contract intact while still letting interceptors rewrite details, and avoids widening %WRITABLE.
- The fork-pool bypass is the one real parity hole left on the activity-interceptor side; closing it would mean relaying Perl-level details (not serialized bytes) up the pool control channel so the parent can run the chain. Worth a spec note if it ever matters.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R73 (nexus operation inbound interceptor) continues the cross-SDK parity work and needs Nexus task semantics.
