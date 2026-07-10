# Session Summary: P10.0.5 integration-test load-stall flake hardening

**Date**: 2026-06-25
**Duration**: ~50 minutes
**Conversation Turns**: ~30
**Estimated Cost**: ~$6 (Opus, heavy test-suite runs)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: prove -lj4 t deterministically green; dev-server integration tests resilient to transient load stalls (P10.0.5 hardening)
- **Mode**: step (single orchestrator-injected hardening item)
- **Outcome**: converged — 8 consecutive full-suite runs under forced CPU contention all exit 0
- **Turn count**: ~30
- **Subagent dispatches**: 1 (this step-executor invocation)
- **Steps completed**: 1 of 1 (P10.0.5 checked off)

## Key Actions

- Audited all `sdk/t/integration/*.t` and `Temporalio::Test::Worker` for transient-load resilience around idempotent reads.
- Added `Temporalio::Test::Worker::await_idempotent($producer, attempts=>3, backoff=>0.5)` with a private `_is_transient_load_error` classifier. RED-first via new `sdk/t/unit/test_worker_retry.t`.
- Initial predicate retried only `RpcTimeout`; verification under contention surfaced a SECOND transient shape (`h2 protocol error: http2 error`, an `RpcError` catch-all). Extended the classifier (RED then GREEN) to also retry UNAVAILABLE and transport-message RpcErrors (h2/http2/connection-reset/broken-pipe/transport-error), while every real non-transient error (NOT_FOUND, QueryRejected, ALREADY_EXISTS, …) still surfaces immediately.
- Wrapped idempotent reads (query, fetch result, schedule describe poll) in `await_idempotent` across signals_queries.t and schedule.t; left non-idempotent start_workflow/signal/terminate un-retried.
- Bumped test-harness ceilings across all 18 integration files: await_future 30→60, await_with_worker/await_result 60→120, shutdown 60→120, schedule await_num_actions 30→60.
- Verified: 8 consecutive `prove -lj4 t` runs under sustained CPU contention (loadavg 6+ on a 4-core box), all PASS / exit 0, 473 tests each.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator P10.0.5 hardening dispatch | TDD: unit RED for retry helper, GREEN in Test::Worker, audit + wrap idempotent reads, bump ceilings, 8x verify under load | Converged; 8/8 PASS |

## Efficiency Insights

**What went well:**
- Verification-under-contention caught the second flake shape (h2 protocol error) that a naive "passes once" run would have missed. The injected "8x under load, do not accept pass-on-retry" rule did its job.
- RED-first for both the initial RpcTimeout predicate and the widened transport-error predicate kept the classifier honest.

**What could improve:**
- The first verification batch (runs 1-4 then 5-8) used the narrow predicate; run 5 failed, forcing a predicate widen and a full 8x re-run. Could have anticipated the broader transient-transport class up front.

**Course corrections:**
- Widened `_is_transient_load_error` from RpcTimeout-only to the full transient-transport set after run 5 surfaced `h2 protocol error`.

## Process Improvements

- When hardening against "transient load stalls," classify the whole transient-transport family (DEADLINE_EXCEEDED + UNAVAILABLE + transport/h2 hiccups), not just the one error observed first.

## Observations

- On this 7.8 GiB / no-swap / 4-core box under loadavg 6+, the dev-server gRPC path raises both DEADLINE_EXCEEDED and bare `h2 protocol error: http2 error` for the same root cause (worker starved mid-call). Both map to idempotent-read retry; neither is a client-timeout bug (client RPC timeout defaults to 0).

## Suggested Skills for Next Session

- None specific. Next step is the regular P10.x plan cadence (pure-Perl TDD); load `temporal:temporal-developer` only if the next step touches workflow/activity semantics.
