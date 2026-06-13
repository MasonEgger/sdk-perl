# Session Summary: Goal Step 32 — execute_activity / start_activity + ResolveActivity (P3.4)

**Date**: 2026-06-13
**Duration**: ~25 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (<$2 — spec/proto/reference reads, one
RED/GREEN cycle with two debugging iterations, full live suite run)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.4.1 RED through P3.4.3 Verify in one commit.
  The workflow body can now CALL ACTIVITIES: `execute_activity` /
  `start_activity` emit a `ScheduleActivity` command, park the body on a
  `Temporalio::Workflow::Future`, and the runner resolves that Future
  imperatively when the matching `ResolveActivity` job arrives.
- **Subagent dispatches**: this summary covers dispatch 32
- **Steps completed**: 3 of 3 P3.4 sub-items (P3.4.1–P3.4.3)

## Key Actions

- Confirmed scope against plan P3.4 + spec section 10.2 (execute_activity
  kwargs) + 10.3 (seq allocation: workflow-scoped, monotonic from 1) +
  10.7 (T-wf-1/2/7). Cancellation outcome (T-wf-12), timers (P3.5),
  dispatcher cache (P3.6), and the full fail/cancel/task-fail outcome table
  (P3.7) remain deferred — this step lets an activity exception bubble out of
  `:Run` (re-raised by `_build_completion`) rather than mapping it to a
  command, which is exactly what T-wf-7 asserts.
- **MUST-match semantics, cross-checked against sdk-python**
  `temporalio/worker/_workflow_instance.py`:
  - `_apply_schedule_command` (lines ~3114–3174): `seq` from `_next_seq`;
    `activity_id = self._input.activity_id or str(self._seq)` (defaults to the
    seq string); `activity_type`; arguments converted to payloads BEFORE the
    command is built (so a converter error surfaces at the call site);
    `task_queue` defaults to the workflow's own task queue; the four timeouts
    become `google.protobuf.Duration`s only when set; `retry_policy`
    `apply_to_proto`; `cancellation_type` cast to the enum int.
  - `_apply_resolve_activity` (lines 810–857): `pop` the pending handle by seq
    (missing -> RuntimeError); `ActivityResolution.status` oneof —
    `completed` -> resolve success with the decoded result (None when no
    result payload), `failed`/`cancelled` -> resolve failure via
    `failure_converter.from_failure`, `backoff` -> local-activity retry
    (deferred, local activities are Phase 6+).
  - `ActivityCancellationType` enum verified against the VENDORED proto
    `sdk/share/proto/temporal/sdk/core/workflow_commands/workflow_commands.proto`:
    `TRY_CANCEL=0`, `WAIT_CANCELLATION_COMPLETED=1`, `ABANDON=2`. Default
    `try_cancel` (0).
  - `ScheduleActivity` field numbers/shape and `ResolveActivity` +
    `ActivityResolution`/`Success`/`Failure`/`Cancellation` shapes read from
    the vendored `workflow_commands.proto`, `workflow_activation.proto`, and
    `activity_result/activity_result.proto`.
- RED (P3.4.1): `sdk/t/replay/activities.t` — 4 subtests:
  - T-wf-1: `execute_activity` on the first (InitializeWorkflow) activation
    emits exactly one `ScheduleActivity` (seq 1, activity_id "1", type
    `SayHello`, one arg round-tripping, start_to_close 60s, cancellation_type
    0); NO completion command yet (body parked on the activity Future).
  - T-wf-2: second activation `ResolveActivity{seq:1, completed}` resumes the
    body -> one `CompleteWorkflowExecution` carrying the post-activity return.
  - T-wf-7: `ResolveActivity{seq:1, failed}` (an `Exception::Activity` whose
    cause is an Application/`BadInput`, rendered through the failure converter)
    -> the await site raises `Temporalio::Exception::Activity` with
    `->cause->type eq 'BadInput'`.
  - seq allocation: a `start_activity`×2 workflow emits seq 1 then 2; an
    activation that resolves seq 2 BEFORE seq 1 still lands each result on its
    own handle (matched by seq, not arrival order).
  - Two fixtures: `t/lib/WfDef/ActivityCaller.pm`, `t/lib/WfDef/TwoActivities.pm`
    (one `:isa` class per file under Future::AsyncAwait — lessons.md).
- GREEN (P3.4.2):
  - `lib/Temporalio/Workflow/Commands.pm` — added the `schedule_activity`
    builder (wraps the assembled field hashref in the `WorkflowCommand` oneof).
  - `lib/Temporalio/Workflow/Runner.pm` — `schedule_activity(%opts)` method
    (seq alloc, arg->payload conversion, the four timeout Durations,
    retry_policy->proto, cancellation_type string->enum, headers, default
    task queue; buffers the command; registers a `Workflow::Future` in
    `%pending_activities{seq}`); `_apply_resolve_activity` job handler
    (`completed`->`->done`, `failed`/`cancelled`->`->fail` via the failure
    converter, unknown seq dies); new `seq_counter`/`%pending_activities`/
    `failure_converter`/`task_queue` fields; `_cancellation_type_number` and
    `_duration` helper subs inside the class block.
  - `lib/Temporalio/Workflow.pm` — `execute_activity`/`start_activity` (resolve
    the activity to a type-name string, delegate to the runner) +
    `_activity_type_name` (string verbatim, or `->name`/`->activity_type`).
- REFACTOR (P3.4.3 fold-in): clarified the Runner POD (Scope + Sequence
  numbers sections) for the activity surface.
- Verify: targeted file green (4 subtests / 24 assertions), then full suite
  `prove -lj4 t` -> 33 files, 200 tests, exit 0 (integration ran LIVE against
  the dev server, not skipped).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.4 execute_activity/start_activity + ResolveActivity job handling; MUST-match ScheduleActivity fields + ResolveActivity result/failure/cancel vs sdk-python `_apply_resolve_activity`/`_apply_schedule_command`; deterministic seq allocation) | Read latest summary + plan P3.4 + spec 10.2/10.3/10.7; cross-checked sdk-python `_workflow_instance.py` + vendored coresdk protos; built RED replay test (4 subtests) + 2 fixtures; added `schedule_activity` builder + runner `schedule_activity`/`_apply_resolve_activity` + Workflow `execute_activity`/`start_activity`; fixed the cross-activation command-buffer bug; full-suite verify; todo update; summary; commit; push | Suite 33 files / 200 tests, exit 0 |

## Efficiency Insights

**What went well:**
- Reading `_apply_schedule_command` directly nailed the two easy-to-miss
  defaults: `activity_id` defaults to the SEQ STRING (not empty), and
  `task_queue` defaults to the workflow's own queue. Asserted both in RED.
- The out-of-order resolution test (resolve seq 2 then seq 1 in one
  activation) validated that the pending-Futures map is keyed by seq and that
  Future::AsyncAwait fires the awaiting continuations synchronously at each
  `->done`, so the body completes deterministically regardless of job order.

**What could improve:**
- Burned one iteration on a cross-activation bug: `@commands` is a runner
  FIELD that persisted across activations, so the second activation's
  completion still carried the FIRST activation's `ScheduleActivity` (2
  commands instead of 1). The worker returns one completion per activation, so
  the command buffer must be CLEARED at the start of each `process_activation`
  — while the seq counter (workflow-scoped) must NOT be. Easy to conflate
  "per-activation" vs "workflow-scoped" runner state.

**Course corrections:**
- Simplified `_activity_type_name` from a placeholder-with-dead-branch to a
  clean string/`->name`/`->activity_type` resolution after the first draft was
  awkward.

## Process Improvements

- Runner state has two lifetimes: WORKFLOW-scoped (seq counter, pending-Futures
  map, the instance, the RNG, run_id) persists across every activation for the
  run; ACTIVATION-scoped (the command buffer, is_replaying, the activation
  timestamp) is reset/overwritten at the top of each `process_activation`. When
  adding new runner fields, classify the lifetime explicitly — a workflow-scoped
  buffer that should be activation-scoped silently double-emits prior commands.

## Observations

- T-wf-7 (activity failure) currently lets the `Exception::Activity` escape
  `:Run`; `_build_completion` re-raises it (the skeleton never swallows
  errors). Mapping that escape to a `FailWorkflowExecution` command — and the
  cancel/task-fail/continue-as-new branches — is the explicit P3.7 outcome
  table. The await-site exception identity and `->cause->type` are already
  correct because the failure converter round-trips the `activity_failure_info`
  variant.
- `start_activity` returns a bare `Temporalio::Workflow::Future` today; the
  richer `ActivityHandle` surface (explicit cancel, separate result accessor)
  grows in a later phase. For v0.1 the Future IS the handle (await it for the
  result; `->cancel` fires the on_cancel chain).
- The `do_not_eagerly_execute`, `versioning_intent`, and `priority`
  ScheduleActivity fields are not yet threaded through — they are optional and
  default-safe (unset), and no current test or spec scenario exercises them at
  the workflow-author layer. They join when their Perl-side options land.

## Suggested Skills for Next Session

- No matching skill for the next step (P3.5: `start_timer`/`sleep` ->
  `StartTimer` command + `FireTimer` job -> resolve the pending-timer Future;
  `CancelTimer` on Future cancel). Ground truth: spec section 10.2 (start_timer/
  sleep) + 10.3 (FireTimer job, the pending-timers map mirroring this step's
  pending-activities map) + 10.7 T-wf-6, and sdk-python `_workflow_instance.py`
  `start_timer`/`_apply_fire_timer` (seq keyed by "timer"). The pending-Futures
  + seq machinery built this step is the direct template. The
  `temporal:temporal-developer` skill is end-user usage guidance, not SDK
  internals.
