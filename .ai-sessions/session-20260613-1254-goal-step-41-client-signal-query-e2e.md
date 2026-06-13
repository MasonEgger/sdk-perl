# Session Summary: Goal Step 41 — client signal/query end-to-end + greet-with-signal example (P4.4)

**Date**: 2026-06-13
**Duration**: ~35 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: moderate (~$3 — survey of sdk-core completion validator + reference SDK query reject mapping, one LIVE integration test that surfaced a real Core-rejection bug, runner fix across two methods, a runnable example exercised against a live dev server, full live suite)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P4.4.1 RED through P4.4.4 Verify in one commit.
  Phase 4 acceptance gate (spec section 11) is now green: a client can
  `$handle->signal('setName', [...])` to drive a Perl worker's `:Signal`
  handler, `$handle->query('currentName')` to read `:Query` state back (decoded),
  and a reject_condition query against a terminated workflow raises QueryRejected.
- **Subagent dispatches**: this summary covers dispatch 41
- **Steps completed**: 4 of 4 P4.4 sub-items (P4.4.1–P4.4.4)

## Key Actions

- Confirmed the client surface already existed: `Temporalio::Client::WorkflowHandle`
  `signal`/`query` (built earlier) issue SignalWorkflowExecution / QueryWorkflow
  via `_rpc_call`, decode the single query payload, and raise QueryRejected on a
  server `query_rejected` response. Verified the request mapping against sdk-ruby
  `workflow_query_reject_condition.rb` (NOT_OPEN = QUERY_REJECT_CONDITION_NOT_OPEN,
  enum 2) and sdk-python `client/_impl.py:433` (`req.query_reject_condition = <int>`)
  + `:459` raises WorkflowQueryRejectedError. So this was an integration step, not
  new feature work.
- **RED (P4.4.1):** wrote `sdk/t/integration/signals_queries.t` (DevServer-backed,
  skip_all without the temporal CLI) plus a fixture `t/lib/WfDef/SignalQueryGreeter.pm`
  (`:Run` waits on `wait_condition(name set?)`, `:Signal('setName')` sets it,
  `:Query('currentName')` reads it). Three subtests: (1) query before signal sees
  empty, signal drives the handler, query after sees 'Ada', result is
  'Hello, Ada!' (T-cli-signal-1, T-cli-query-1); (2) terminate then query with
  reject_condition NOT_OPEN raises QueryRejected (T-cli-query-2). RED confirmed:
  the live worker crashed.
- **Bug the live path revealed (the GREEN core):** the worker died with Core's
  "Workflow completion had a legacy query response along with other commands"
  rejection. Root cause: a **legacy query** (query_id "legacy_query",
  sdk-core `LEGACY_QUERY_ID`) is delivered on its own workflow task; Core replays
  history to rebuild state, and during that replay the buffered `setName` signal
  unblocked `wait_condition` so the runner emitted a CompleteWorkflow alongside
  the QueryResult. Core rejects any completion that mixes a legacy-query response
  with other commands (sdk-rust `worker/workflow/mod.rs:1264-1278`).
- **GREEN (P4.4.2) — two runner fixes:**
  1. Gated the wait_condition re-check by job-set index in `process_activation`:
     `_pump(check_conditions => ($set_index == 1 || $set_index == 2))` — TRUE only
     after the signal set (1) and the non-query set (2), FALSE after patches (0)
     and queries (3). MUST-match sdk-python `activate()` line 471
     (`_run_once(check_conditions=index==1 or index==2)`). `_pump` now takes a
     `check_conditions` kwarg defaulting to TRUE.
  2. Legacy-query command suppression in `_successful_completion`: when the
     command buffer contains a RespondToQuery whose query_id is "legacy_query",
     filter the buffer down to ONLY query-response commands before building the
     proto. The workflow's own commands were already in history; only the query
     answer is new. Added `_is_query_response` and `_has_legacy_query_response`
     helpers (the respond_to_query sub-message is a plain hashref, not blessed —
     read `->respond_to_query->{query_id}`, lessons.md proto-blessing gotcha).
- **Example (P4.4.3):** created `sdk/examples/greet-with-signal/` mirroring
  `examples/hello-world/`: `lib/GreetWithSignal/GreetingWorkflow.pm` (the
  signal/query workflow), `worker.pl`, `starter.pl` (starts, queries empty,
  signals, queries the name, awaits "Hello, <name>!"), and a README with a Mermaid
  sequence diagram. RAN IT end-to-end against a live `temporal server start-dev`:
  `starter.pl Ada` printed the empty-then-'Ada' query progression and
  "Hello, Ada!"; worker + server shut down with no orphaned processes.
- **Verify (P4.4.4):** full live suite `prove -lj4 t` -> 42 files, 245 tests,
  exit 0 (up from 41/242). Confirmed integration ran LIVE via a separate
  `prove -l t/integration/` -> 7 files / 27 tests, exit 0, no skip_all.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P4.4 — client signal/query end-to-end + greet-with-signal example) | Verified client signal/query already implemented + the query-reject mapping against sdk-ruby/sdk-python; wrote signals_queries.t + SignalQueryGreeter fixture (RED — live worker crashed on Core's legacy-query rejection); diagnosed against sdk-core `mod.rs` + sdk-python `activate()`; gated `_pump` conditions by job-set index and added legacy-query command suppression in `_successful_completion` (GREEN); built + RAN the greet-with-signal example against a live dev server; full live-suite verify; todo update; summary; commit; push | Suite 42 files / 245 tests, exit 0; example runs end-to-end |

## Efficiency Insights

**What went well:**
- The RED test surfaced the bug immediately and the error string ("legacy query
  response along with other commands") pointed straight at sdk-core's completion
  validator — grepping the error verbatim in `sdk-rust/crates/` found the exact
  rule (`mod.rs:1264`) and the `LEGACY_QUERY_ID = "legacy_query"` sentinel.
- sdk-python `activate()` had the canonical fix already (`check_conditions=index==1
  or index==2`); our runner had been pumping conditions after EVERY job set, which
  was the latent bug — replay-to-answer-a-legacy-query advanced the body.
- Two complementary fixes (don't advance on the query set; suppress non-query
  commands when a legacy query is present) cover both the "fresh query activation"
  and the "replay rebuilds + completes" paths defensively.

**What could improve:**
- The legacy-query path is only reachable LIVE (Core decides when to issue one),
  so the replay suite never caught it — a reminder that the integration gate is
  load-bearing, not redundant with replay tests.

## Process Improvements

- When a live worker dies with a Core-side "malformed workflow completion"
  message, grep the verbatim error string in the `sdk-rust/crates/sdk-core`
  checkout: the validator that produced it documents the exact lang-SDK contract
  being violated (here, the legacy-query command-suppression rule).
- Mirror sdk-python's `activate()` job-set gating exactly when touching the
  condition-recheck location: conditions are checked after sets 1 and 2 ONLY, never
  after patches (0) or queries (3).

## Observations

- A query against a terminated workflow logs a benign Core WARN
  ("Workflow task not found.") — server-side, not a Perl error; the subtest still
  passes (QueryRejected is raised from the client RPC response).
- `_pump(check_conditions => ...)` defaults to TRUE so the registration-time
  re-check inside `wait_condition` (a direct `_check_conditions` call, not via
  `_pump`) is unaffected.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — usage-level confirmation for P5.1 (cancellation
  end-to-end: `$handle->cancel` -> CancelWorkflow -> in-flight activity token
  cancels -> result raises WorkflowFailure cause Cancelled). Ground truth remains
  spec section 11 Phase 5 + the reference SDKs' cancel propagation (sdk-python
  `_workflow_instance.py` cancel handling, sdk-ruby cancel path). This is a
  DevServer-backed integration step like P4.4, likely needing a
  RequestCancelActivity command from Workflow::Future on_cancel + worker-side
  token wiring.
