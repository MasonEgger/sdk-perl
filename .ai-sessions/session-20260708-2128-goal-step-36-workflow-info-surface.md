# Session Summary: R36 Complete the Workflow info() Surface

**Date**: 2026-07-08
**Duration**: ~15 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (pure Perl: three lib edits, one fixture, one replay test; no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R36 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R36, finding A5: info() missing workflow_id/attempt/task_queue, POD linked a nonexistent class)

## Key Actions

- Confirmed Python parity before coding: `sdk-python/temporalio/workflow/_context.py` Info names the fields `workflow_id`, `attempt`, `task_queue`, and `worker/_workflow.py` sources workflow_id/attempt from the InitializeWorkflow job but task_queue from the WORKER (the activation proto carries no queue).
The Perl Runner already took `task_queue` as a constructor param (the live WorkflowDispatcher passes it), so the fix surfaces that param rather than inventing an activation source.
- RED: new `t/replay/workflow_info.t` plus fixture `t/lib/WfDef/InfoReporter.pm` (its :Run returns info() verbatim).
Two subtests: the three new fields carry init/worker values, and the six pre-R36 fields (run_id, workflow_type, namespace, patches, search_attributes, memo) are unchanged.
Pre-fix failure observed: the harness rejected the `task_queue` constructor param ("Unrecognised parameters"), both subtests failed.
- GREEN, three files:
`Test/WorkflowReplay.pm` gains a `task_queue :param` threaded to the Runner (mirroring `namespace`), documented in its constructor POD.
`Workflow/Runner.pm` gains `field %init_info` seeded at the top of `_apply_initialize` (`workflow_id // ''`, `attempt // 0`, the proto3 scalar defaults Python also gets) and `info()` now spreads `%init_info` plus `task_queue => $task_queue`; the `=head2 info` POD names the full field list.
`Workflow.pm` POD for `info` no longer links the nonexistent `Temporalio::Workflow::Info` class; it names the nine fields that actually ship.
- REFACTOR folded into GREEN: all init-derived info fields are sourced from the single `%init_info` struct, with the field comment citing finding A5 and the Python Info field list per the plan.
- Seeding placement matters: `%init_info` is seeded before the buffered signal/update drain in `_apply_initialize`, so signal-with-start handlers already see the full info surface.
- Verify: `prove -lj4 t` exit 0 (150 files, 677 tests, integration live against the dev server), `prove -lj4 xt` exit 0 (318, POD coverage and syntax green with the corrected POD).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (step R36) | Full RED/GREEN/REFACTOR for the info() surface (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Reading the Python Info construction site (`worker/_workflow.py:682-712`) before designing the test settled the one open question (where task_queue comes from) in a single grep, avoiding a wrong "carry it on the activation" design the todo wording hinted at.
- The RED constructor failure ("Unrecognised parameters ... task_queue") was cheap, honest RED evidence that also pinned the harness gap.

**What could improve:**
- Nothing notable; smallest step of the phase so far.

**Course corrections:**
- None; the plan's file pointers were accurate this time.

## Process Improvements

- None new; the step followed the established replay-harness pattern (runner_basics.t) verbatim.

## Observations

- The todo phrase "task_queue carries init-activation values" is loose: InitializeWorkflow has no task_queue field. Spec R36's actual contract ("populated from the activation/init data" + Python-parity test note) is satisfied by worker-sourced task_queue, which is exactly Python's sourcing.
- plan.md's phase checkbox list (line 64 etc.) is not maintained by prior steps; todo.md is the tracker, so R36 was checked off only there.
- Next unchecked step is R35 (validate activity options at the call site: required timeout + unknown-key rejection with Temporalio::Exception::Argument at Runner.pm execute_activity/execute_local_activity; new replay test activity_option_validation.t; shared validator shape aligned with R44/R55).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R35 needs the Python required-timeout rule for activities (`workflow.start_activity` raises without start_to_close/schedule_to_close) as the parity reference.
