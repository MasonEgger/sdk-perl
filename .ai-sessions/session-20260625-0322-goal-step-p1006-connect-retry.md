# Session Summary: P10.0.6 centralized dev-server transient-fault tolerance

**Date**: 2026-06-25
**Duration**: ~1.5 hours
**Conversation Turns**: ~30
**Estimated Cost**: ~$6 (Opus, integration-test batch dominated wall time)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: P10.0.6 hardening — every dev-server touch transient-fault tolerant in one centralized place; full `prove -lj4 t` 12x consecutive, 4 under CPU load, all exit 0
- **Mode**: step (single orchestrator-injected hardening step)
- **Outcome**: converged (12/12 passing, fix committed and pushed)
- **Subagent dispatches**: 1 (this step-executor invocation)
- **Steps completed**: 1 (P10.0.6 checked off)

## Key Actions

- Diagnosed the new connect mode: an ephemeral dev server passes its 60s start_timeout but binds/accepts a moment after `Temporalio::Client->connect`, so core's ~5s connect window expires against a not-yet-listening socket. The bridge surfaces it as `Temporalio::Exception::RpcError` with message `Connection failed: ...ConnectionRefused...` (confirmed in sdk-rust testing.rs / ephemeral_server/mod.rs).
- RED-first: extended `t/unit/test_worker_retry.t` with connect-shape classifier assertions and `await_with_retry` / `start_workflow_with_retry` cases; added `t/unit/test_client_connect_retry.t`.
- Extended the ONE shared `_is_transient_load_error` classifier (in `Temporalio::Test::Worker`) to match connect-refused / tcp connect error / "failed connecting to" / TonicTransport shapes — reused by connect, idempotent read, and teardown. Verified it does NOT match the genuine TLS-mismatch "Connection failed: ...handshake..." (which carries none of the connect-refused tokens), preserving `client_connect.t` failure-path tests.
- Added `Temporalio::Test::Client::connect_with_retry($loop, $connector, attempts=>10, backoff=>1.5)` and routed every integration client connect through it. Left the two intentional connect-FAILURE assertions in `client_connect.t` (TLS mismatch, bad PEM) calling connect directly.
- Mid-batch the FIRST 12-run attempt failed twice (run7, run9, both under load) with "Timeout expired" in `signals_queries.t` — a recurrence of the P10.0.5 DEADLINE_EXCEEDED on the NON-idempotent start_workflow/signal that P10.0.5 left un-retried. Folded in the fix rather than restarting blind: added `await_with_retry` (retries a transient timeout, tolerates WorkflowAlreadyStarted on a start retry as proof the prior RPC landed) + `start_workflow_with_retry` convenience, routed all integration start/signal/terminate sites through them, and raised the `await_idempotent` default ceiling to 6 attempts / 1.0s backoff.
- Restarted a clean 12-run batch after the fix; all 12 green (4 under forced `yes` CPU load).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| P10.0.6 hardening (orchestrator-injected) | Full TDD: classifier + connect_with_retry + await_with_retry, audited all integration files, 12x verification under load | 12/12 PASS, committed + pushed |

## Efficiency Insights

**What went well:**
- Reading the sdk-rust source (testing.rs, ephemeral_server/mod.rs) pinned the exact connect-failure message shape, so the classifier could be precise rather than guessed.
- Keeping the genuine-failure negative assertions in the unit test caught the risk that a broad "Connection failed" match would wrongly retry the TLS-mismatch test.

**What could improve:**
- The first 12-run batch only surfaced the non-idempotent timeout mode at run7/9. Could have pre-emptively converted the non-idempotent calls when I saw P10.0.5 had explicitly left them un-retried — that is exactly the "next mode" the task warned about.

**Course corrections:**
- After run7/9 failed, did not commit; diagnosed the mode, added `await_with_retry` centrally, converted ~25 start sites, and restarted the full batch from scratch.

## Process Improvements

- When a fix targets "stop the whack-a-mole", proactively cover the sibling code paths the previous fix explicitly excluded (here: non-idempotent calls), not just the newly-observed mode.

## Observations

- `start_workflow` rejects unknown options, so `start_workflow_with_retry` must peel `attempts`/`backoff`/`timeout` out of the start opts before forwarding — a unit test now guards that.
- The dev server is online on this host, so integration tests run (not skip); `nexus.t` still skips without TEMPORAL_NEXUS_ENDPOINT.

## Suggested Skills for Next Session

- None specific. The next plan step (P10.1+) is pure-Perl interceptor/feature work; load `temporal:temporal-developer` if workflow-semantics ground truth is needed.
