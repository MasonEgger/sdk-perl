# Session Summary: Nexus caller side (P9.1)

**Date**: 2026-06-24
**Duration**: ~45 minutes
**Conversation Turns**: 1 (autonomous step-executor dispatch)
**Estimated Cost**: ~$3 (Opus, large-context reads of spec/protos/reference SDK)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: Phase 9 Nexus — P9.1 caller side green (prove -lj4 t exits 0; T-nexus-1..9 replay)
- **Mode**: step
- **Outcome**: converged (this step) — Nexus caller-side replay contract green
- **Turn count**: 1
- **Subagent dispatches**: 1 (this executor)
- **Steps completed**: 3 of 3 P9.1 sub-items (P9.1.1/.2/.3) folded into one commit

## Key Actions

- Added two `Workflow::Commands` builders: `schedule_nexus_operation($fields, $summary_payload)` (oneof arm 21; ScheduleNexusOperation has NO user_metadata field of its own, so summary rides on the WorkflowCommand `user_metadata.summary` like timers/local-activities) and `request_cancel_nexus_operation($seq)` (arm 22). MUST-matched the field names against `workflow_commands.proto:358/401` — note the SINGLE `input` Payload (field 5, not a repeated `arguments`), `nexus_header` (a plain string->string map, field 7), and `cancellation_type` (field 8).
- New caller surface: `Workflow.pm::create_nexus_client(endpoint=>, service=>)` (sync, non-command, mirrors `get_external_workflow_handle`), `Workflow/NexusClient.pm` (async `start_operation($op,$arg,%opts)` / `execute_operation`; takes ONE positional $arg, not an args arrayref), and `Workflow/NexusOperationHandle.pm` (two-stage start/result Futures + operation_token + cancel; carries endpoint/service/operation for the failure wrapper).
- Runner: separate `$nexus_operation_seq_counter` + `%pending_nexus_operations` (mirrors the child-workflow two-stage map). `start_nexus_operation` converts the single arg, three timeouts, cancellation_type, summary, headers BEFORE buffering; pre-scheduled cancel raises Cancelled immediately. `_apply_resolve_nexus_operation_start` (operation_token->async keep seq / started_sync->sync keep seq / failed->pop+fail start, NO result job) and `_apply_resolve_nexus_operation` (completed->done; failed/cancelled/timed_out->fail). Cancel propagation in `_apply_cancel_workflow` + evict cleanup + dispatch-table entries.
- `_nexus_cancellation_type_number`: DEFAULT `wait_cancellation_completed`=0 (the Nexus proto ZERO, unlike activities=try_cancel and child workflows=wait_cancellation_completed=2). Verified the enum against `core/nexus/nexus.proto:84` (WAIT_CANCELLATION_COMPLETED=0, ABANDON=1, TRY_CANCEL=2, WAIT_CANCELLATION_REQUESTED=3).
- Wrote `t/replay/nexus.t` (11 subtests, T-nexus-1..9) + four WfDef fixtures (NexusCaller, NexusStarter, NexusCanceller, NexusPreCancelled).
- Verified: prove -lj4 t (62 files, 388 tests) green; prove -lj4 xt (POD coverage, 242) green.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute next unchecked todo (P9.1) | TDD RED+GREEN+Verify in one commit | Nexus caller-side replay green; full suite + author tests pass |

## Efficiency Insights

**What went well:**
- Running `t/replay/nexus.t` alone first caught two real issues cheaply: a `my $h` declared inside a `defined(...) && %$h` condition (out of scope), and the failure-wrapper double-wrap.

**What could improve:**
- First failure-mapping draft DOUBLE-wrapped: the runner called `from_failure` on the wire failure (which is ALREADY a nexus_operation_execution_failure with the inner as cause, yielding a NexusOperation) and then wrapped THAT in another NexusOperation, so `cause->which_failure_info` was `nexus_operation_execution_failure_info` instead of the expected `application/timeout/canceled`. Fix: call `from_failure` and only re-wrap when the result is NOT already a NexusOperation (matching sdk-python, which just calls from_failure on the arm).

## Process Improvements

- For a nexus resolve failure, trust the wire shape: `ResolveNexusOperation{failed/cancelled/timed_out}` carries a `nexus_operation_execution_failure` Failure whose `cause` is the mapped inner, so a single `from_failure` call yields the spec §26.4 NexusOperation-with-mapped-cause. Only manufacture a NexusOperation wrapper as a fallback for a bare inner failure.

## Observations

- The spec mandates unknown-seq nexus resolve -> non-determinism (T-nexus-9), but sdk-python `_apply_resolve_nexus_operation` TOLERATES an unknown seq (returns, to handle the WaitRequested cancel double-resolve race). Spec wins per the prime directive; followed the codebase's child-workflow `_record_nondeterminism` pattern on both unknown-seq paths.
- The pre-scheduled-cancel replay path (T-nexus-8 last clause) needs a fixture that catches a CancelWorkflow-driven Cancelled (unwinding a timer await), THEN schedules the nexus op while `$cancel_requested` is set — `start_nexus_operation` calls `$handle->cancel` immediately when the run is already cancel-requested.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — P9.2 (Nexus handler side) reimplements the nexusrpc slice natively (attribute pattern :NexusService/:SyncOperation/:WorkflowRunOperation, NexusDispatcher mirroring the activity dispatcher, gRPC->Nexus error-type MUST-match table from sdk-python `_nexus.py`); sdk-python is the sole reference (Ruby runs the handler in Go core).
