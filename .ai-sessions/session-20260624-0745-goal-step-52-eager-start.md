# Session Summary: P7.3 eager start (spec section 23)

**Date**: 2026-06-24
**Duration**: ~30 minutes
**Conversation Turns**: 1 (autonomous bpe:step-executor dispatch)
**Estimated Cost**: ~$2.30
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: Phase 7 P7.3 eager start green (T-eager-1..6), full `prove -lj4 t` exits 0
- **Mode**: step
- **Outcome**: converged (P7.3 complete)
- **Turn count**: 1
- **Subagent dispatches**: 1 (this dispatch)
- **Steps completed**: 3 of 3 P7.3 sub-items (RED + GREEN + Verify folded into one commit)

## Key Actions

- RED: wrote `sdk/t/unit/eager.t` (T-eager-1 request_eager_execution on the
  wire; T-eager-2/3 `WorkflowHandle->eagerly_started` off the response, both via
  a directly-built handle and via a mocked `_rpc_call` returning a response with
  and without `eager_workflow_task`; T-eager-4 `no_remote_activities` ->
  `enable_remote_activities=0` via the P0.10 debug-echo path; T-eager-6
  `disable_eager_activity_execution` -> `do_not_eagerly_execute` on the emitted
  ScheduleActivity via the replay harness) and `sdk/t/integration/eager.t`
  (T-eager-2 live; T-eager-5 schedule-to-start timeout on a no-remote worker).
  T-eager-1 passed immediately (request flag already wired at Client.pm:304);
  the other four unit subtests failed for the expected missing-feature reasons.
- GREEN, eager workflow start (detect-only):
  - `Temporalio::Client::WorkflowHandle` gained a read-only `eagerly_started`
    field (default 0) + accessor + POD.
  - `Client->start_workflow` sets `eagerly_started => (defined
    $response->eager_workflow_task ? 1 : 0)`. Verified the Perl proto layer
    reports an unset optional message field as undef and a set one as defined
    (`defined $response->eager_workflow_task` is the presence check).
    `signal_with_start_workflow` is left at the default (its response has no
    `eager_workflow_task` and signal-with-start does not support eager).
- GREEN, eager activity dispatch (two distinct knobs):
  - `no_remote_activities` (default 0) — a bridge WorkerOptions field. `Worker.pm`
    now packs `enable_remote_activities => $no_remote_activities ? 0 : 1`
    (was hardcoded 1).
  - `disable_eager_activity_execution` (default 0) — a workflow-side flag.
    Threaded `Worker -> WorkflowDispatcher -> Runner`; `schedule_activity` sets
    `do_not_eagerly_execute => 1` on the ScheduleActivity command when true
    (MUST-match sdk-python `_workflow_instance.py:3173`).
  - `Test::WorkflowReplay` exposes `disable_eager_activity_execution` as a
    constructor kwarg so T-eager-6 is unit-testable without a worker.
- Fixture: `WfDef::EagerActivityWorkflow` (schedules SayHello with a 2s
  schedule_to_start timeout) for T-eager-5.
- Updated POD: WorkflowHandle `eagerly_started` head2 + Worker DESCRIPTION
  paragraph on the two eager-activity knobs (xt/pod-coverage.t enforces this).
- Updated `todo.md` (P7.3.1-P7.3.3 checked).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute next todo item (P7.3) | TDD RED->GREEN for eager start | All sub-items done, full suite green, integration passes live |

## Efficiency Insights

**What went well:**
- T-eager-4/6 were both verifiable WITHOUT a live server: T-eager-4 via the
  existing P0.10 `debug_worker_options` echo, T-eager-6 via the replay harness's
  ScheduleActivity command output. Only T-eager-2/5 needed the dev server.
- The dev server actually returned an eager workflow task, so T-eager-2 asserted
  real eager start (not just the skip path).

**What could improve:**
- Caught the POD-coverage failure only after running xt (the WorkflowHandle
  accessor is a naked method). Next time add the POD `=head2` in the same edit
  that adds the accessor.

**Course corrections:**
- Two subtest-closing `};` typos (should be `});`) — same fragment family as the
  prior session's note; fixed before running.

## Process Improvements

- When adding a read-only accessor to a class that has POD-coverage enforced in
  xt, add the `=head2 <name>` POD stanza in the SAME edit as the `method` — the
  WorkflowHandle 93.8% failure is purely a documentation gap, not a logic bug.

## Observations

- Eager workflow start is detect-only by design: the C header has no eager API,
  the Rust core owns the embedded first-task dispatch when client+worker share a
  core client, and the lang layer never routes the embedded task. The accessor
  is the entire surface.
- `do_not_eagerly_execute` is field tag 14 on ScheduleActivity
  (`workflow_commands.proto:97`); set by name, so the Perl proto layer handles
  the tag automatically.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — next is P7.4 in-workflow upsert of search
  attributes & memo (spec section 24): typed-only SA value_set/value_unset,
  memo hashref with undef-deletes, UpsertWorkflowSearchAttributes (tag 18) /
  ModifyWorkflowProperties (tag 19) commands, replay tests. Closes the Phase 7
  activity-parity acceptance gate.
