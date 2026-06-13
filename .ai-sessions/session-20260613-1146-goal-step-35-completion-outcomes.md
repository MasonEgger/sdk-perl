# Session Summary: Goal Step 35 — completion-outcome decision table + continue_as_new + CancelWorkflow + non-determinism (P3.7)

**Date**: 2026-06-13
**Duration**: ~40 minutes (single autonomous subagent dispatch)
**Estimated Cost**: moderate (<$3 — spec/proto/reference reads, one RED/GREEN/REFACTOR cycle, one regression-test update, full live suite)
**Conversation Turns**: 1 orchestrator dispatch
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.7.1 RED through P3.7.3 Verify in one commit.
  The Runner's `_build_completion` is now the full spec section 10.3 step 6
  OUTCOME DECISION TABLE: normal return, FailWorkflowExecution (Temporal /
  listed-class exceptions), task-failure (plain die / unlisted class), Cancel
  (Cancelled after CancelWorkflow), ContinueAsNew, and non-determinism (task-
  fail by default, workflow-fail when configured).
- **Subagent dispatches**: this summary covers dispatch 35
- **Steps completed**: 3 of 3 P3.7 sub-items (P3.7.1–P3.7.3)

## Key Actions

- Confirmed scope against plan P3.7 + spec section 10.3 step 6 (the decision
  table) + the T-wf-8/12/13/15a/b/c test IDs (spec lines 2082–2104).
- **MUST-match semantics, cross-checked against sdk-python
  `worker/_workflow_instance.py`:**
  - `_run_top_level_workflow_function` (lines 2516–2565) is the literal decision
    table. Order matters: `_ContinueAsNewError` is caught FIRST (before the
    generic Exception branch) so continue-as-new is never converted as a
    failure; then `self._cancel_requested && is_cancelled_exception(err)` →
    `cancel_workflow_execution`; then `workflow_is_failure_exception(err)` →
    `_set_workflow_failure` (FailWorkflowExecution); else
    `_current_activation_error = err` (the TASK-failure path — the whole
    activation completion is `failed`).
  - `workflow_is_failure_exception` (lines 1820–1835): an escaped value fails
    the WORKFLOW if it is a `FailureError` (the Temporal-failure base — our
    analog is any `Temporalio::Exception::*`), a TimeoutError, or an instance of
    a class in the worker-/workflow-level `failure_exception_types`. Mapped to
    `Runner::_is_workflow_failure_exception` (isa Temporalio::Exception OR isa a
    class in `workflow_failure_exception_types`).
  - `_ContinueAsNewError._apply_command` (lines 3493–3543): continue-as-new does
    NOT re-use the old run's args; it sets workflow_type/task_queue/arguments/
    timeouts/retry_policy/memo/headers/search_attributes only when provided.
    Mirrored by `Runner::_build_continue_as_new_command` over the
    `ContinueAsNewWorkflowExecution` proto (workflow_commands.proto lines
    193–222, field names verified verbatim).
- RED (P3.7.1): `sdk/t/replay/completion_outcomes.t` — 9 subtests covering
  T-wf-11 (baseline), T-wf-15a/b/c (task vs workflow fail, listed vs unlisted
  non-Temporal class), T-wf-8 (continue_as_new args+type+task_queue), T-wf-12
  (CancelWorkflow cancels the pending activity Future → CancelWorkflowExecution),
  T-wf-13 (unknown-seq non-determinism: task-fail default / workflow-fail when
  `nondeterminism_as_workflow_fail`). Eight fixtures added under `t/lib/WfDef/`
  (TaskFailer, AppFailer, CustomError + CustomFailer, ContinueAsNewer,
  CancelAwaiter).
- GREEN (P3.7.2):
  - `lib/Temporalio/Workflow/ContinueAsNew.pm` — NEW. A PLAIN blessed control
    signal (deliberately NOT a `Temporalio::Exception` subclass so the decision
    table never mistakes it for a failure), mirroring sdk-python
    `_ContinueAsNewError`. Carries the continue-as-new options.
  - `lib/Temporalio/Exception/Nondeterminism.pm` — NEW. A Temporal exception
    whose outcome the decision table special-cases by the
    `nondeterminism_as_workflow_fail` flag.
  - `lib/Temporalio/Workflow.pm` — added `continue_as_new($workflow_or_string,
    %opts)` (dies the control signal; never returns) + `_workflow_type_name`.
  - `lib/Temporalio/Workflow/Commands.pm` — added
    `continue_as_new_workflow_execution($fields)`.
  - `lib/Temporalio/Workflow/Runner.pm` — added `workflow_failure_exception_types`
    + `nondeterminism_as_workflow_fail` params, a run-scoped `$cancel_requested`
    flag, a per-activation `$nondeterminism_error` stash; `_apply_cancel_workflow`
    (fails pending activity Futures with Cancelled, cancels timers + the main run
    Future); `_apply_resolve_activity` now STASHES a non-determinism error for an
    unknown seq instead of `die`ing (so context teardown + completion build still
    run); and rewrote `_build_completion` as the full decision table delegating
    to `_outcome_for_failure` / `_workflow_failed_completion` /
    `_task_failed_completion` / `_successful_completion` /
    `_build_continue_as_new_command`.
  - `lib/Temporalio/Test/WorkflowReplay.pm` — threaded the two new outcome-policy
    params to the Runner; refactored `push_activation` to delegate to a new
    `push_activation_completion` (exposes the raw completion so a test can assert
    a `failed`-status TASK failure) + `commands_of`.
- REFACTOR: POD on Runner (full decision-table section), Commands (new builder +
  set note), Workflow (functional-surface description now lists continue_as_new).
- **Regression update**: `sdk/t/replay/activities.t` T-wf-7 previously asserted
  the SKELETON behavior (a failed activity `die`d out of `process_activation`).
  P3.7 legitimately changes this: an escaped `Exception::Activity` is a Temporal
  failure → FailWorkflowExecution. Updated the subtest to assert the command is
  `fail_workflow_execution` and its failure-cause chain preserves the underlying
  application error type (`BadInput`).
- Verify: `prove -lj4 t/replay` → 4 files / 22 tests, exit 0; full
  `prove -lj4 t` → 36 files / 221 tests, exit 0 (integration ran LIVE against the
  dev server); `prove -lj4 xt` → NOTESTS (no author tests).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.7 — completion outcome decision table + continue_as_new + CancelWorkflow; MUST-match vs sdk-python `_workflow_instance.py`) | Read latest summary + plan P3.7 + spec section 10.3 step 6 + the ContinueAsNew/completion protos; cross-checked sdk-python `_run_top_level_workflow_function`/`workflow_is_failure_exception`/`_ContinueAsNewError._apply_command`; built RED (9 subtests, 8 fixtures); added ContinueAsNew signal + Nondeterminism exception + continue_as_new function + command builder + the Runner decision table + harness pass-through; updated the T-wf-7 regression; full live-suite verify; todo update; summary; commit; push | Suite 36 files / 221 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The timer-cancel precedent (`_TimerFuture` failing with Cancelled rather than
  Future-native cancel) was the exact template for CancelWorkflow's pending-
  activity-Future teardown — failing the futures with `Exception::Cancelled`
  makes the await site raise a proper Temporal cancellation that the decision
  table can then route to CancelWorkflowExecution.
- Reading sdk-python's `_run_top_level_workflow_function` ONCE settled the
  branch ORDER definitively (continue-as-new first, cancel gated on
  cancel_requested, then is-failure-exception, then task-fail), which the Perl
  `_outcome_for_failure` mirrors line-for-line.

**What could improve:**
- The T-wf-7 regression in activities.t was foreseeable from the fixture's own
  comment ("the full outcome table is P3.7; this fixture just lets it bubble").
  Could have grepped for tests asserting the skeleton `die` behavior BEFORE
  running the suite, rather than discovering it on the first full replay run.

## Process Improvements

- When a step replaces a documented-as-temporary skeleton branch (here:
  `_build_completion`'s `die $failure[0]`), grep the existing tests for
  assertions against that temporary behavior up front — they are guaranteed
  regressions and updating them is part of the GREEN step, not a surprise.

## Observations

- A workflow-FAILURE completion DISCARDS any commands already buffered this
  activation (`_workflow_failed_completion` resets `@commands` to just the fail
  command), matching sdk-python which adds only the fail command. A failing run
  does not also replay its earlier partial commands.
- A TASK failure uses the `failed` oneof arm of `WorkflowActivationCompletion`
  (a `Failure { failure }`), carries NO commands, and `push_activation` returns
  `()` for it — hence the new `push_activation_completion` harness method so
  task-failure tests can inspect `which_status eq 'failed'` directly.
- `Temporalio::Workflow::ContinueAsNew` must NOT be a `Temporalio::Exception`:
  if it were, `_is_workflow_failure_exception` would match it (isa
  Temporalio::Exception) and emit FailWorkflowExecution. It is identified purely
  by class in `_outcome_for_failure`, caught before the failure branch — exactly
  the sdk-python ordering.

## Suggested Skills for Next Session

- No matching skill for the next step (P3.8: determinism primitives —
  UpdateRandomSeed re-seed, logger gating during replay (T-wf-9, Log::Any test
  adapter), NotifyHasPatch recording). Ground truth: spec section 10.4 +
  sdk-python `_workflow_instance.py` (random/logger/patch handlers) + sdk-ruby.
  Heed lessons.md: `Math::Random::ISAAC::XS` is the spec-mandated RNG primitive
  (the current Runner ships a placeholder xorshift). The
  `temporal:temporal-developer` skill is end-user usage guidance, not SDK
  internals.
