# Session Summary: R14+R15 Route Failure Options to Live Runners

**Date**: 2026-07-08
**Duration**: ~20 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (two new test files, four surgical plumbing edits, one full-suite run, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R14+R15 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (merged step R14+R15, findings A1/ADJ2: failure-routing options never reached live Runners)

## Key Actions

- Verified the Python ground truth for core's two nondeterminism fields (`../sdk-python/temporalio/worker/_workflow.py:742-756`): core's `nondeterminism_as_workflow_fail_for_types` is a set of WORKFLOW TYPE names derived from per-definition `failure_exception_types` (a surface the Perl SDK does not expose), while the boolean derives from the worker-level types.
The Perl worker was packing EXCEPTION class names into that per-type field and passing neither option to the live dispatcher, so live Runners ran with defaults while `Test/WorkflowReplay.pm` threaded both (the live/replay divergence findings A1 and ADJ2 describe).
- RED: `sdk/t/unit/dispatcher_failure_options.t` (dispatcher-to-Runner arrival via new readers, Worker-to-dispatcher arrival, and the core echo asserting `nondeterminism_as_workflow_fail_for_types=[]` with the boolean still `true`) and `sdk/t/replay/failure_exception_types.t` (each of the four scenarios, listed vs unlisted exception type and nondeterminism with vs without the flag, driven through BOTH the replay harness and a live-path dispatcher, asserting identical workflow-fail vs task-fail outcomes).
Pre-fix the live dispatcher rejected both params with "Unrecognised parameters" and the echo showed the misroute, exactly the documented defect.
- GREEN: `Worker/WorkflowDispatcher.pm` grew both `:param` fields and threads them to every Runner; `Worker.pm` `_build_workflow_dispatcher` passes both and `_build_worker_options` now sends `[]` for core's per-type field (boolean unchanged); `Workflow/Runner.pm` gained the two readers; `t/unit/worker_new.t:200-202` no longer pins the misroute.
- REFACTOR: the plumbing keys are named once at the dispatcher boundary in `_runner_failure_options` (comment cites A1/ADJ2 and requires the Runner-constructor names verbatim); `Test/WorkflowReplay.pm` field comment cross-cites the dispatcher helper; dispatcher POD documents the two constructor params and readers.
- Verify: both new files green; `prove -lj4 t` green (140 files, 640 tests, integration live against the dev server); `prove -lj4 xt` green (314, after adding the dispatcher POD entries Pod::Coverage demanded). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for merged step R14+R15 (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- The existing live-dispatcher scaffolding from R11 (`t/replay/failed_activation_completion.t`) and the replay-harness decision-table coverage (`t/replay/completion_outcomes.t`) meant both halves of every parity subtest had a proven template.
- Driving each scenario through both paths in one file directly encodes the spec acceptance ("a replay test and a live-shaped test drive the same workflow die and assert the same outcome") and will catch any future drift in either direction.

**What could improve:**
- First RED run tripped on the workflow-type naming rule: a `:Run` method named `run` registers under the class base name (`CustomFailer`), not `run`. One-line fixture-job fix.

**Course corrections:**
- None beyond the workflow-type naming fix above.

## Process Improvements

- When a fix flips documented-wrong behavior, grep the test suite for assertions that PIN the wrong behavior before writing GREEN (here `worker_new.t:200-202` asserted the misroute by name); flipping them is part of the same diff, not collateral damage discovered by a red suite later.

## Observations

- Core still receives the `nondeterminism_as_workflow_fail` boolean so its own replayer honors it; only the per-workflow-TYPE set stays empty (the Perl surface has no per-definition failure exception types, unlike Python).
- The subtests that exercised BOTH paths with defaults (unlisted type, flag unset) passed pre-fix on both paths, confirming the divergence was strictly in the option-set direction.
- Next unchecked step is R17 (settle updates from cancelled handler futures without croaking in `_settle_update`), a Runner-internal Future-state fix with an eviction replay test.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R17 concerns update-handler settlement during eviction; same workflow-semantics ground truth as this step.
