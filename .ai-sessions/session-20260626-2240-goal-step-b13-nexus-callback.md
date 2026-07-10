# Session Summary: B13 C-NEXUS-CALLBACK — :WorkflowRunOperation Async Completion (#11)

**Date**: 2026-06-26
**Duration**: ~50 minutes
**Conversation Turns**: ~35 (single autonomous dispatch)
**Estimated Cost**: ~$7 (Opus, heavy reference-SDK + proto reading)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: Execute the B13 cluster (B13.1 RED … B13.5 Verify) per plan.md "Step B13" — resolve #11 (`:WorkflowRunOperation` async never completes for the caller).
- **Mode**: step (one BPE step / one commit)
- **Outcome**: converged (all of B13.1–B13.5 done, one commit)
- **Steps completed**: 5 of 5 B13 sub-steps checked off

## Key Actions

- DIAGNOSED the mechanism against sdk-python `nexus/_operation_context.py` + `_link_conversion.py` and `client/_impl.py`: a WorkflowRunOperation backing-workflow start must carry `completion_callbacks` (a `Callback.Nexus{url,header}`), the inbound caller links converted to `workflow_event` links, and the Nexus `request_id` as the start idempotency key. Confirmed PURELY PERL, NO SHIM — the inbound `StartOperationRequest` already carries `callback`/`callback_header`/`request_id`/`links` (proto fields 3–7) and `StartWorkflowExecutionRequest` already exposes `completion_callbacks`(21)/`links`(24)/`on_conflict_options`(26) plus `Callback.Nexus`.
- B13.1 RED: wrote subprocess-guarded `t/integration/repro_nexus_callback.t` + three fixtures (`WfDef::NexusWorkflowRunCaller`, `NexusDef::WorkflowRunHandler`, `WfDef::NexusBackingWorkflow`). Pre-fix it failed (the parked-operation teardown died non-zero).
- B13.2/B13.3 GREEN: dispatcher `_handle_start` now copies the inbound callback/header/request_id/links onto the `WorkflowRunOperationContext`; `start_workflow` builds the `Callback`, converts links via the new `Temporalio::Nexus::Link` (MUST-match sdk-python), and passes `completion_callbacks`/`links`/`request_id` to the client; `Client::_populate_start_request` places them and sets `on_conflict_options` when a callback is present.
- B13.4 REFACTOR: all wiring lives in one place (`WorkflowRunOperationContext::start_workflow`) with a #11 comment; link conversion isolated in `Temporalio::Nexus::Link`.
- Added server-free unit `t/unit/nexus_callback.t` proving callback/header/request_id/link attachment + link conversion (deterministic, immune to live flakiness).
- B13.5 Verify: live GREEN repro resolves with 'Hello, world!'; full suite green; ROOT-CAUSE-MAP.md marks #11 resolved and the fd theory dead.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute the B13 cluster, diagnose first, one commit | Diagnosed vs reference SDKs, wrote RED repro + fixtures, implemented Perl-only fix, added unit test, ran full suite, updated map/todo | All B13 sub-steps done, one commit |

## Efficiency Insights

**What went well:**
- Reading sdk-python's exact `_get_callbacks`/`_get_links`/`_build_start_workflow_execution_request` pinned the precise field set before writing code — no guessing.
- The deterministic unit test caught the enum-by-name bug (`event_type expected enum, got 'EVENT_TYPE_…'`) instantly, before any live run.

**What could improve:**
- The first RED live run piped prove through `| tail`, and an orphaned dev server (the guard's process-group kill missed it after the child SIGSEGV'd on parked-operation teardown) held the pipe open, making the run appear to hang for 13 minutes. Redirect to a file (`> out 2>&1`) for subprocess-guarded live tests instead of piping.

**Course corrections:**
- Switched live-test output from a `tail` pipe to a file after the pipe-wedge.

## Process Improvements

- For subprocess-guarded live integration tests, always `> file 2>&1` rather than `| tail` — an orphaned dev server can hold a pipe's write end open and wedge the shell long after prove exits.
- When setting a proto enum field in the pure-Perl Protobuf dist, pass the NUMBER (resolve via `Temporalio::Core::Proto::schema()->enum($full_name)->values`), not the symbolic name — the generated message classes validate enum fields as integers.

## Observations

- The fd theory for #11 is now definitively dead: the only gap was the missing async completion callback, exactly as B8 pass-2 instrumented.
- This unblocks all three nexus samples (nexus-hello, nexus-messaging, nexus-cancellation), which all use `:WorkflowRunOperation`.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — the next steps (B8 reconciliation pass: revert the #10/#11 sample gates and verify the nexus samples live) are Temporal workflow/nexus semantics work.
