# Session Summary: Step R79, Expose Per-Activation Workflow Info Accessors

**Date**: 2026-07-09
**Duration**: ~15 minutes
**Conversation Turns**: 1 (autonomous dispatch)
**Estimated Cost**: low (single step-executor dispatch)
**Model**: claude-fable-5

## Goal Context

- **Condition**: execute todo.md step R79 (per-activation workflow info accessors, parity in-workflow finding 3), one commit
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (R79.1 through R79.4 checked; full suite green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1

## Key Actions

- Verified the Python target first: `workflow/_context.py:140,165,175,185` (the four Info METHODS) delegate to `_workflow_instance.py`, which captures `history_length`, `history_size_bytes`, `continue_as_new_suggested`, and `deployment_version_for_current_task` at the activate() boundary (`:427-429`) and derives build_id as '' when no deployment version (`:1195-1198`).
- Probed the vendored proto and the Protobuf dist: round-tripped activations bless `deployment_version_for_current_task` properly; unset scalars decode to proto3 zeros, the unset sub-message to undef.
- RED: `sdk/t/replay/workflow_activation_info.t` plus `WfDef::ActivationInfoProbe` (its :Run snapshots the four accessors once per `probe` signal, so snapshot N carries activation N's delivered values; second subtest asserts the field-less defaults 0/0/''/false).
Pre-fix failure confirmed honest via `push_activation_completion`: "Undefined subroutine &Temporalio::Workflow::get_current_history_length".
- GREEN: capture at the top of `Runner::process_activation` (next to is_replaying/timestamp), Runner accessor methods, and `Temporalio::Workflow` package delegators (the is_replaying/random surface shape).
- REFACTOR: the four scalars became one `%activation_info` field hash assigned wholesale at the boundary; comments cite in-workflow finding 3, `_context.py:140-185`, and `_workflow_instance.py:427-429`; the Workflow.pm comment documents the methods-on-Info to package-functions spec section 0 surface deviation; POD added in both files and info()'s POD now points at the live readers.
- Verify: `prove -lj4 t` green (176 files, 792 tests, live integration included); `prove -lj4 xt` green (422, after pod-coverage demanded the four Runner =head2 entries).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: R79, per-activation info accessors | RED replay test + fixture, boundary capture + accessors through Runner/Workflow, struct refactor, POD | Step complete, suites green, one commit |

## Efficiency Insights

**What went well:**
- Probing the proto round-trip semantics up front (blessed sub-message, proto3 zero defaults) meant the defaults subtest was written correctly on the first pass.
- `wait_condition.t` / `CounterWaiter` were direct templates for the park-then-resume two-activation flow.

**What could improve:**
- The first fixture draft snapshotted from the :Signal handler; the RED came back as a silently-successful empty completion instead of a loud failure, costing one debug loop (see Observations).

**Course corrections:**
- Moved the accessor snapshots from the `probe` :Signal handler into :Run so a die reaches the task-failure funnel and the RED failure message is honest and loud.

## Process Improvements

- None beyond what lessons.md already carries.

## Observations

- A SYNCHRONOUS :Signal handler that dies is silently swallowed: `_dispatch_signal` wraps the handler in `Future->call`, and an already-ready (failed) future is deliberately not tracked in `%in_progress_handlers`, so nothing observes the failure and the activation completes successfully. Python fails the workflow task on a signal-handler exception. This smells like a real parity gap worth auditing separately; it is NOT covered by R79 and was not touched this step.
- The activation proto carries no bare `build_id` field at this pin; the only source is `deployment_version_for_current_task.build_id` (message field 9), matching Python's `_deployment_version_for_current_task` derivation.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R80 (max_concurrent_nexus_tasks worker kwarg) works against `worker/_worker.py:31,129-133` and the tuner slot-supplier packing.
