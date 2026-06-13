# Session Summary: Goal Step 39 — workflow query dispatch + RespondToQuery (P4.2)

**Date**: 2026-06-13
**Duration**: ~25 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (<$2 — survey of sdk-python `_apply_query_workflow` + the existing signal-dispatch path, one RED test with four subtests/two fixtures, one GREEN pass, full live suite)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P4.2.1 RED through P4.2.3 Verify in one commit. QueryWorkflow jobs now DISPATCH to `:Query` handlers and emit a RespondToQuery command; the `:Query` attribute registration from P3.1 is wired to actual handler invocation and the query-result command.
- **Subagent dispatches**: this summary covers dispatch 39
- **Steps completed**: 3 of 3 P4.2 sub-items (P4.2.1–P4.2.3)

## Key Actions

- Confirmed scope against plan P4.2 + spec section 10.3 (QueryWorkflow) and
  verified semantics against sdk-python `worker/_workflow_instance.py`:
  `_apply_query_workflow` (named -> dynamic, read-only, RespondToQuery with
  `succeeded.response` or `failed`) and `activate()`'s job-set 3 (queries last,
  run with `check_conditions=False`). Confirmed proto field names against
  `workflow_commands.proto` (`QueryResult { query_id, oneof succeeded|failed }`,
  `QuerySuccess { response }`) and `workflow_activation.proto`
  (`QueryWorkflow { query_id, query_type, arguments }`).
- **RED (P4.2.1):** wrote `sdk/t/replay/queries.t` with four subtests and two
  fixtures (`WfDef::QueryGreeter`, `WfDef::DynamicQueryGreeter`): (1) T-wf-4 a
  query against an in-flight (timer-parked) workflow returns the handler's value
  via RespondToQuery and does NOT complete the workflow; (2) a dying query
  handler produces a RespondToQuery FAILED variant carrying the error message,
  the completion stays `successful`, and no fail/complete-workflow command leaks;
  (3) an unmatched query name routes to the dynamic catch-all `:Query(dynamic=1)`
  handler called with `(name, @args)`; (4) queries-last — a QueryWorkflow listed
  before a SignalWorkflow in the same activation still observes the post-signal
  state because the runner orders queries into job-set 3. Confirmed 4/4 RED.
- **GREEN (P4.2.2):**
  - `Temporalio::Workflow::Commands::respond_to_query($query_id, %parts)` — wraps
    `QueryResult` in the WorkflowCommand oneof; `response => $payload` sets
    `succeeded.response`, `failure => $failure` sets `failed`.
  - `Temporalio::Workflow::Runner`: routed `query_workflow` in `_apply_job`;
    added `_apply_query_workflow` (resolve named-or-dynamic handler; missing
    handler -> query-failed RespondToQuery; run handler via
    `Future->call(sub { Future->wrap(...) })` per the lessons idiom; a failed
    Future -> query-failed RespondToQuery; a ready value -> succeeded
    RespondToQuery) and `_resolve_query_handler` (mirrors the signal resolver:
    `queries{$name} or dynamic{query}`). Added `use Temporalio::Exception ()`.
  - Queries reuse the EXISTING `_ordered_job_sets` set 3 (no change needed — the
    queries-last slot was already in place from P4.1).
- **Verify (P4.2.3):** `prove -lj4 t` -> 40 files / 239 tests, exit 0
  (integration ran LIVE against the dev server). queries.t: 4 subtests, all green.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P4.2 — QueryWorkflow dispatch + RespondToQuery) | Verified semantics against spec section 10.3 + sdk-python; wrote queries.t + 2 fixtures (RED 4/4); implemented the respond_to_query command builder, query dispatch (named/dynamic/missing/dying), and the query handler resolver (GREEN); full live-suite verify; todo update; summary; commit; push | Suite 40 files / 239 tests, exit 0 |

## Efficiency Insights

**What went well:**
- Query dispatch fell straight out of the signal-dispatch shape from P4.1: same
  `Future->call(sub { Future->wrap(...) })` idiom, same named-or-dynamic resolver
  structure, same `_ordered_job_sets` (queries-last was already wired). The only
  genuinely new code is the failure-as-command branch (a dying query becomes a
  RespondToQuery FAILED, never bubbling to `_build_completion`).
- queries-last needed ZERO runner change — the set-3 slot from P4.1 already
  ordered queries after signals; the test simply proves it.

**What could improve:**
- The query handler is read immediately as a synchronous-in-effect Future
  (`$future->result` / `$future->failure` right after `Future->call`). A query
  handler that tried to `await` (illegal — queries must be synchronous and must
  not command) would leave the Future pending and the current code would treat a
  pending Future as a void success. A later hardening pass could detect a
  non-ready query Future and convert it to a query failure ("query handler
  attempted to await/command").

**Course corrections:**
- The first GREEN run failed only in the TEST: I called `query_id`/`succeeded`
  on the WorkflowCommand wrapper instead of the inner `respond_to_query`
  message. Fixed the test helper to return `$cmd->respond_to_query`. The runner
  code passed unchanged.

## Process Improvements

- For a runner job-kind that produces its OWN response command and must never
  fail the workflow (queries, and later update responses), catch the handler
  outcome inside the apply method and push the command directly — do NOT let the
  handler error reach `_build_completion`'s outcome decision table.

## Observations

- A query failure is delivered as a `RespondToQuery { failed }` command on a
  `successful` completion — the completion status and the query result are
  orthogonal. The dying-handler subtest asserts BOTH (status `successful` AND a
  `failed` query variant) to lock this in.
- `which_variant` works on the nested `QueryResult` oneof (succeeded|failed),
  not just the top-level WorkflowCommand — confirmed empirically before writing
  the assertions.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — usage-level confirmation of `wait_condition`
  semantics for P4.3 (a predicate flipped by a signal resumes the awaiting
  continuation in the same activation; a timeout kwarg rejects the wait with
  Timeout semantics; predicates re-checked each pump iteration). Ground truth
  remains spec section 10.2 + sdk-python `workflow.wait_condition` /
  `_workflow_instance` condition handling.
