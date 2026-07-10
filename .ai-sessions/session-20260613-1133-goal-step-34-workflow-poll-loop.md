# Session Summary: Goal Step 34 — workflow poll loop + WorkflowDispatcher cache + RemoveFromCache eviction + Worker drives both loops (P3.6)

**Date**: 2026-06-13
**Duration**: ~30 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (<$2 — spec/proto/reference reads, one
RED/GREEN cycle with one blessed-submessage debugging iteration, full suite)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.6.1 RED through P3.6.4 Verify in one commit.
  The WORKFLOW side of the worker is now wired: activations are polled from
  core, routed by `run_id` to a cached per-run `Workflow::Runner`, pumped, and
  the produced commands sent back. `RemoveFromCache` tears the run's Runner
  down and returns an empty-success completion (the §8.3 eviction fast path),
  applied LAST when combined with other jobs. `Worker->run` now drives the
  activity loop (P2.4) and the workflow loop concurrently with the established
  shutdown sequence.
- **Subagent dispatches**: this summary covers dispatch 34
- **Steps completed**: 4 of 4 P3.6 sub-items (P3.6.1–P3.6.4)

## Key Actions

- Confirmed scope against plan P3.6 + spec section 8.3 (workflow poll loop
  steps 1–10: poll, undef→exit, decode, eviction fast path, codec decode,
  route by run_id, process, codec encode, complete) + section 10.3
  RemoveFromCache (eviction tears down the runner; applied last if combined).
- **MUST-match semantics, cross-checked against the reference SDK:**
  - **Eviction is a fast path checked FIRST.** sdk-python `_workflow.py`
    `_handle_activation` (lines 249–264): scan jobs, if any
    `remove_from_cache` job is present it short-circuits to
    `_handle_cache_eviction` and returns — regardless of other jobs (logs a
    warning if `len(act.jobs) != 1`). That is exactly "eviction-last" semantics:
    other jobs in the same activation are NOT processed; the run is torn down
    and an empty-success completion is sent. The dispatcher mirrors this with a
    `_has_eviction` scan + `_handle_eviction`.
  - **Per-run cache keyed by run_id.** sdk-python `_running_workflows` dict
    keyed by `act.run_id` (lines 279, 331, 548). A cache miss requires the
    activation to carry an `InitializeWorkflow` job (`init_job`); a miss with no
    init job is a `RuntimeError` ("workflow could have unexpectedly been removed
    from cache", lines 281–284). The dispatcher's `%runners` + `_runner_for`
    mirror this (raising `Temporalio::Exception::Bridge` on the miss-with-no-init
    case), routing the init job's `workflow_type` through the WorkflowRegistry.
  - **Eviction tolerates a cache miss.** `_handle_cache_eviction` (line 547+)
    looks up `_running_workflows.get(act.run_id)` and proceeds whether or not it
    is present; an uncached run still gets an empty-success completion.
  - **Codec boundary at the worker, not the runner.** sdk-python
    `decode_activation` (line 320) decodes inbound payloads and
    `encode_completion` (line 428) encodes outbound, while the runner converts
    values with the bare converter. The Perl Runner already used a plain
    payload_converter; the new dispatcher applies codecs at the boundary.
- RED (P3.6.1): `sdk/t/unit/workflow_poll_loop.t` — 7 subtests:
  - run_id routing: a new run creates+caches a Runner (StartTimer on init), a
    later activation on the same run reuses the SAME Runner (FireTimer →
    completion).
  - distinct run_ids get distinct Runners.
  - eviction-only activation (T-wf-14): empty-success completion, runner
    dropped, no workflow code invoked.
  - eviction for an uncached run: still empty-success, no error.
  - RemoveFromCache combined with other jobs: eviction wins (runner torn down,
    empty-success) — eviction-last.
  - codec decode on inbound activation payloads + encode on outbound completion
    (SpyCodec records calls; WfDef::Constant exercises both boundaries).
  - poll loop dispatches activations until the ShutDown sentinel (reused the
    generic PollLoop + a DispatcherStub, mirroring activity_dispatch.t).
- GREEN (P3.6.2):
  - `lib/Temporalio/Core/FFI.pm` — attached `worker_poll_workflow_activation`
    + `worker_complete_workflow_activation` (same shapes as the activity pair;
    signatures read from the pinned sdk-rust C header, never from memory).
  - `lib/Temporalio/Converter/Data.pm` — added public `codec_encode` /
    `codec_decode` (codec-chain-only over a payload list; the worker-boundary
    need that does not run value conversion).
  - `lib/Temporalio/Workflow/Runner.pm` — added `evict` (cancel all pending
    activity/timer Futures + the main run Future, clear the maps).
  - `lib/Temporalio/Worker/WorkflowDispatcher.pm` — NEW. run_id cache, eviction
    fast path, codec boundary (decode init/signal/query args + resolve-activity
    result inbound; encode complete_workflow_execution.result + schedule_activity
    args outbound), routing via WorkflowRegistry, injectable completer.
- GREEN (P3.6.3): `lib/Temporalio/Worker.pm` — build the WorkflowRegistry in
  ADJUST (spec 8.6); `run` now builds an activity loop AND a workflow loop and
  drives both via `Future->wait_all`, surfacing the first sub-future failure;
  added `_build_workflow_dispatcher`, `_poll_workflow_activation`,
  `_complete_workflow_activation` (mirroring the activity helpers).
- REFACTOR: POD updates on Worker (SYNOPSIS + DESCRIPTION now describe both
  loops + the WorkflowDispatcher) and the new WorkflowDispatcher POD.
- Verify: targeted file green (7 subtests), then full suite `prove -lj4 t` ->
  35 files, 212 tests, exit 0 (integration ran LIVE against the dev server).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.6 — workflow poll loop + WorkflowDispatcher run_id cache + RemoveFromCache eviction-last + codec boundary + Worker drives both loops; MUST-match vs sdk-python `_workflow.py`) | Read latest summary + plan P3.6 + spec 8.3/10.3; cross-checked sdk-python `_workflow.py` `_handle_activation`/`_handle_cache_eviction`/`_running_workflows` + the vendored workflow_activation/workflow_completion protos + C header; built RED unit test (7 subtests); attached FFI workflow poll/complete; added Data codec_encode/decode + Runner evict + WorkflowDispatcher; wired Worker->run to drive both loops; full-suite verify; todo update; summary; commit; push | Suite 35 files / 212 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The activity poll loop (P2.4) was a precise structural template. The generic
  `PollLoop` was reused verbatim for the workflow loop; the WorkflowDispatcher
  mirrors ActivityDispatcher's shape (decode → route → process → inject
  completer); the FFI attaches are identical to the activity pair; the
  Worker poll/complete helpers ported almost line-for-line.
- Reading sdk-python `_handle_activation` settled the eviction-last question
  definitively: the cache-remove job short-circuits BEFORE any other job runs,
  which is exactly the "applied last / other jobs ignored" semantics the plan
  describes. Asserted in a dedicated combined-jobs subtest.

**What could improve:**
- Burned one iteration on unblessed sub-messages. The Runner builds its
  completion from nested hashrefs (`successful => { commands => [...] }`), so
  the generated `successful` accessor returns an UNBLESSED hashref until the
  proto is round-tripped through encode/decode. The first dispatcher draft
  walked `$completion->successful->commands` directly and died with "Can't call
  method commands on unblessed reference". Fixed by round-tripping the
  completion through `decode($completion->encode)` before the codec-encode walk
  — exactly what the WorkflowReplay harness already does for the same reason.

## Process Improvements

- Any code that walks a proto built via `->new` from nested hashrefs must first
  round-trip it through `decode(->encode)` to bless every sub-message before
  calling accessors on them. The generated classes leave nested hashrefs
  unblessed at `->new` time; only on-the-wire decode blesses the whole tree.
  This bit the WorkflowReplay harness (already round-trips) and now the
  WorkflowDispatcher. It will recur anywhere we inspect a Runner-built
  completion or a hand-built activation before sending — round-trip first.

## Observations

- The codec boundary walks the specific payload-bearing fields of the v0.1
  job/command kinds the runner handles (initialize/signal/query args +
  resolve-activity result inbound; complete-workflow result + schedule-activity
  args outbound) rather than a generic recursive Payload walker. This matches
  the existing per-field pattern in `Converter::Data::_apply_codecs_to_failure`
  and is sufficient until later phases add more payload-bearing kinds; a generic
  walker can replace it if the field list grows unwieldy.
- `Worker->run` uses `Future->wait_all` (not `wait_any`) so neither loop is
  abandoned mid-task — a still-running completion must be sent before the worker
  finalizes. wait_all never itself fails, so the run method inspects each
  sub-future after both settle and re-throws the first failure.
- The dispatcher's `task_queue` is handed to each Runner as the default queue
  for activities the workflow schedules without an explicit queue (sdk-python
  parity); the replay harness leaves it undef (empty string default).

## Suggested Skills for Next Session

- No matching skill for the next step (P3.7: completion outcomes — the spec
  §10.3 step 6 decision table: cancel/fail/task-fail/continue-as-new,
  CancelWorkflow handling, T-wf-12/15a/b/c/8/13). Ground truth: spec section
  10.3 step 6 + sdk-python `_workflow_instance.py` outcome handling
  (`_apply_cancel_workflow`, the activation-completion failed vs
  FailWorkflowExecution distinction) + sdk-ruby worker workflow outcome code.
  The `temporal:temporal-developer` skill is end-user usage guidance, not SDK
  internals.
