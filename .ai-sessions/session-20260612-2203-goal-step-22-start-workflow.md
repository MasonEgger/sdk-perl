# Session Summary: Goal Step 22 — start_workflow + WorkflowHandle (P1.10)

**Date**: 2026-06-12
**Duration**: ~35 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (<$2 — reference-SDK reads, proto introspection one-liners, one live dev-server integration run, full-suite run)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P1.10.1 RED through P1.10.5 Verify in one
  commit. The client can now start workflows: `start_workflow`,
  `signal_with_start_workflow`, `execute_workflow`, `get_workflow_handle`,
  plus the fields-only `Temporalio::Client::WorkflowHandle`.
- **Subagent dispatches**: this summary covers dispatch 22
- **Steps completed**: 5 of 5 P1.10 sub-items (P1.10.1–P1.10.5)

## Key Actions

- MUST-match field mapping verified against reference SDK source per the
  CLAUDE.md non-negotiable. NOTE: the sdk-python layout differs from
  CLAUDE.md's stated path — the request builder lives in
  `temporalio/client/_impl.py` (`_populate_start_workflow_execution_request`,
  lines 279–342), not `temporalio/client.py`. Quoted ground truth:
  - **StartWorkflowExecutionRequest field mapping** — _impl.py 298–342:
    namespace (from client), workflow_id (=id), workflow_type.name,
    task_queue.name, input.payloads (args via data converter),
    workflow_execution_timeout/workflow_run_timeout/workflow_task_timeout
    (Duration), identity (from client), request_id (`str(uuid.uuid4())`),
    workflow_id_reuse_policy, workflow_id_conflict_policy, retry_policy,
    cron_schedule, memo, search_attributes, user_metadata
    (static_summary/details — parked for a later phase here), header,
    workflow_start_delay (Duration), priority, versioning_override.
    request_eager_execution is set in `_build_start_workflow_execution_request`
    (213).
  - **id_reuse/id_conflict enum numbers** — introspected DIRECTLY from the
    vendored proto via `Temporalio::Core::Proto::schema->enum(...)->values`
    (each value is a plain hashref `{ name, number }`), cross-checked against
    sdk-python common.py WorkflowIDReusePolicy (111–127) /
    WorkflowIDConflictPolicy (131–148):
    reuse — unspecified 0, allow_duplicate 1, allow_duplicate_failed_only 2,
    reject_duplicate 3, terminate_if_running 4;
    conflict — unspecified 0, fail 1, use_existing 2, terminate_existing 3.
    Default (undef kwarg) → 0 (unspecified), matching the proto default.
  - **signal_with_start** — _impl.py 247–270: same populate body plus
    signal_name + signal_input.payloads (signal_args via converter). Verified
    the SignalWithStart request shares the entire start-request field set.
  - **memo/header encoding** — sdk-python
    `converter/_data_converter.py:268` `_encode_memo_existing`: each value
    becomes one Payload via `encode([v])[0]`, keyed by name in the proto
    `fields` map. Mirrored: each value → one Payload via `to_payloads([v])`,
    map keyed by name. Both Memo and Header are `map<string, Payload>`
    (FieldsEntry) — introspected.
- Proto ground truth introspected, not assumed: full field list of
  Start/SignalWithStart-WorkflowExecutionRequest, the Response carries
  `run_id` (used as both run_id and first_execution_run_id on the handle),
  WorkflowType{name}, TaskQueue{name}, Payloads{payloads repeated}.
- RED (P1.10.1): `sdk/t/unit/start_workflow_request.t` — 10 subtests:
  full-kwargs field mapping (args→payloads, timeouts→Duration, policies,
  retry/cron/priority, memo/header maps, search attributes, encode/decode
  round-trip); minimal-request omissions; both policy-string→enum tables
  (T-cli-start-3); invalid policy → Argument (T-cli-start-4); required
  id/task_queue guards; signal_with_start variant + signal guard;
  get_workflow_handle (no RPC). Built a client with `connection => undef`
  since the builder never touches the connection.
- GREEN (P1.10.2): new `Client/WorkflowHandle.pm` (fields only per spec §7.6)
  + workflow ops on `Client.pm` (`start_workflow`, `execute_workflow`,
  `signal_with_start_workflow`, `get_workflow_handle`, async builders
  `_build_start_workflow_request` / `_build_signal_with_start_workflow_request`
  sharing `_populate_start_request`, plus the policy-enum tables and the
  `_duration`/`_new_uuid`/`_coerce_search_attributes` helpers).
- RED (P1.10.3) + GREEN (P1.10.4): `sdk/t/integration/start_workflow.t` —
  ran LIVE against the dev server (temporal CLI at ~/.local/bin). T-cli-start-1
  (handle workflow_id + run_id) and T-cli-start-2 (second start of a still-
  running id with reject_duplicate → WorkflowAlreadyStarted, carries the wf
  id). Unique per-pid/random workflow id so reruns don't collide.
- Verify (P1.10.5): full suite `prove -lj4 t` → 22 files, 123 tests, exit 0
  (integration ran live, not skipped). No temporal processes left over
  (pgrep clean). todo.md P1.10.1–5 checked; plan.md Current Status updated
  (next: P1.11).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P1.10 start_workflow + WorkflowHandle), verify Start/SignalWithStart request field mapping + reuse/conflict enums against sdk-python/sdk-ruby, run integration live | Ground-truth reads (_impl.py populate/build/signal-with-start, common.py enums, _data_converter memo), proto enum + field introspection, RED unit + integration tests, GREEN WorkflowHandle + Client workflow ops, live integration run, full-suite verify, plan/todo updates, summary, commit, push | Suite 22 files / 123 tests, exit 0; T-cli-start-1..4 green |

## Efficiency Insights

**What went well:**
- Introspecting both the enum value tables AND the full request field list
  from the vendored proto up front meant `_populate_start_request` mapped
  every field correctly on the first write — no mid-GREEN field-name misses.
- Catching the read-only-proto-accessor behavior early (a one-liner showed
  `$req->signal_name("x")` silently no-ops) turned the one signal-test
  failure into a clean refactor (merge `%extra` into `new`) rather than a
  hunt.

**What could improve:**
- The first unit-test draft assumed sdk-python's str→json/plain encoding for
  args/memo/header. In THIS SDK a bare Perl string is a byte buffer and the
  P1.4 composite (BinaryPlain before Json) encodes it binary/plain — the
  prior session already flagged this exact composite-ordering trap in
  lessons.md. Re-reading that lesson before drafting the args assertions
  would have saved one RED cycle. (The CODE was right; the test expectation
  was wrong — fixed the test, not the code.)

**Course corrections:**
- Generated proto messages are immutable after construction — every field,
  including the SignalWithStart-only signal_name/signal_input, must be passed
  to `new(\%fields)`. Refactored the signal builder to collect extras into a
  `%extra` hash that the shared populator merges into the constructor args.

## Process Improvements

- When a step builds a proto message incrementally, set ALL fields via
  `new(\%fields)` from the start — the generated accessors are read-only and
  setters fail silently (no error), which is a quiet bug source.
- Before asserting payload encodings in a new test, recall that this SDK
  encodes bare Perl strings as binary/plain (not json/plain) because a string
  is a byte buffer and BinaryPlain precedes Json in the composite order.

## Observations

- CLAUDE.md points at `sdk-python/temporalio/client.py` for start_workflow
  ground truth, but the current sdk-python checkout splits the client into
  `temporalio/client/_client.py` (public) and `temporalio/client/_impl.py`
  (the request builders). Future client steps should look in `_impl.py`.
- The handle's run_id and first_execution_run_id are both set from the start
  response's single `run_id` field — there is no separate first-run id on the
  StartWorkflowExecutionResponse.
- static_summary/static_details (→ user_metadata) and versioning_override are
  accepted-and-ignored for now (parked for a later phase); genuine typo
  kwargs still raise Argument via the leftover-keys check.

## Suggested Skills for Next Session

- No matching skill for the next step (P1.11 WorkflowHandle->result +
  describe/cancel/terminate + list/count is terminal-event decoding / RPC /
  async-iterator work over the existing _rpc_call path — the
  temporal:temporal-developer skill is end-user SDK-usage guidance, not
  SDK-internals; no Perl skill exists in the registry). Reference ground
  truth: sdk-python `client/_impl.py` (result/describe/cancel/terminate
  builders) + spec §7.6 result decision table.
