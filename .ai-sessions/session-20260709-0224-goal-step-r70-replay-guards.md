# Session Summary: R70 Repro-Guard Conversion to Replay Tests

**Date**: 2026-07-09
**Duration**: ~30 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: medium (one full live suite run at 189s plus targeted replay runs; no cargo)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R70 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (finding T10, spec R70: 10 integration repro guards skipped offline while only 4 replay guards existed)

## Key Actions

- Surveyed all 10 `t/integration/repro_*.t` guards against existing offline coverage before writing anything.
Three regressions had NO offline guard; three already had offline twins from earlier remediation steps; four genuinely need a live server.
- RED: three new replay tests on the R8-R10 `Temporalio::Test::WorkflowReplay` harness, each reproducing the exact guarded shape:
  - `t/replay/repro_cancel_wait_condition.t` (#5, from repro_cancel_live.t): cancel of a never-true wait_condition park emits exactly one CancelWorkflowExecution, no timer workaround.
  - `t/replay/repro_cancel_mid_update.t` (#8): cancel landing while a `park` :Update handler is mid-flight (accepted, parked) produces a successful completion with one CancelWorkflowExecution, no wedge.
  - `t/replay/repro_external_signal.t` (#2): TwiceSignaller's SECOND SignalExternalWorkflowExecution is emitted only by the activation resolving the first (the hand-off after the first grant), and TwiceCounter completes with count 2 only after both ticks.
- Mutation check (noted in the test comment): disabling the `@conditions` sweep entry in `Runner::_apply_cancel_workflow` (:2580-2583) made BOTH cancel guards fail ("exactly one CancelWorkflowExecution" got 0); reverted, green again, `git diff` on Runner.pm empty.
- GREEN: deleted the six converted integration guards: repro_cancel_live.t, repro_cancel_mid_update.t, repro_condition_timeout_rearm.t (replay twin predates this step), repro_external_signal.t, repro_interceptor_headers.t (offline twins: t/unit/workflow_inbound_headers.t + t/unit/start_workflow_request.t), repro_interceptor_inbound.t (offline twin: t/unit/worker_inbound_interceptor.t).
Live smoke coverage for cancel / external signal / updates remains in cancellation.t, external_workflow.t, updates.t.
- Kept four server-only guards with a why-comment stating why replay cannot express them: repro_fd_signal.t (process-level SIGCHLD reaper vs sdk-core's dev-server child), repro_local_activity.t (live worker core options + core validation SEGV), repro_nexus.t (handler-side Nexus poll loop + provisioned endpoint), repro_nexus_callback.t (handler start-request callback + server-side notification).
- REFACTOR: annotated the three pre-existing offline twins as THE R70 replacements for their deleted integration guards; updated the four WfDef fixture ABOUTMEs (NeverCondition, UpdateParker, TwiceSignaller, TwiceCounter) from "LIVE integration fixture" to replay fixtures.
- Verify: `prove -lj4 t` green (156 files, 727 tests, live integration included), `prove -lj4 xt` green (403 assertions).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (step R70) | Converted 6 of 10 offline-skipping repro guards to offline guards (3 new replay tests, 3 pre-existing twins), kept 4 server-only guards with justification, mutation-checked the conversion | Step complete, suites green |

## Efficiency Insights

**What went well:**
- Grepping t/unit and t/replay for existing twins BEFORE writing conversions cut the new-test work in half: the interceptor guards and the condition-rearm guard were already offline-guarded by earlier remediation steps, so their conversion was deletion plus annotation, not new code.

**What could improve:**
- Nothing notable; the harness conventions in repro_cancel_ext_signal.t were a direct template and every new test passed on the first run.

**Course corrections:**
- None.

## Process Improvements

- When a plan step says "convert X to Y", inventory what Y-form coverage already exists first; conversions may already be half-landed by earlier steps.

## Observations

- The `@conditions` sweep in `_apply_cancel_workflow` is the single fix site behind both #5 and #8; one mutation invalidated both new cancel guards, which is good evidence they bite.
- The integration repro population is now 4 files, all with an explicit server-only justification; every SDK-semantic regression from the B-series lives offline.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — the next step (R56-R59 converter batch) checks Python-parity converter behavior against ../sdk-python.
