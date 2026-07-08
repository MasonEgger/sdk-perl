# Session Summary: R24 Uniform Read-Only Guard for Queries and Command APIs

**Date**: 2026-07-08
**Duration**: ~25 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one new exception class, one fixture, one test file, targeted Runner.pm edits; pure Perl, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R24 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R24, finding R8=L11: patched, child-signal, external-signal, and external-cancel bypassed `_assert_writable`, and query handlers never entered a read-only context, so a query could emit commands)

## Key Actions

- Confirmed Python parity ground truth before writing anything: `_workflow_instance.py` asserts at the head of `workflow_patch`, `signal child handle`, `signal external handle`, `cancel external handle`, and runs the whole query handler inside `_as_read_only`; a `ReadOnlyContextError` from a query is caught by the generic except and becomes a failed query response, never a task failure.
- RED: new `sdk/t/replay/query_readonly.t` table-drives the four bypassing APIs through the new `WfDef::ReadOnlyProber` fixture (its `:Run` starts a child so the query holds a live handle, then parks; its `probe` :Query dispatches on the api-name argument).
Each read-only arm asserts the FAILED query response, the `Temporalio::Exception::ReadOnly` type on the wire, the action label in the message, no leaked command, and no terminal command; four writable-context arms reuse the existing Patcher/ChildSignaller/ExternalSignaller/ExternalCanceller fixtures.
Pre-fix: exactly the four read-only subtests failed (query succeeded and leaked the command), writable arms passed.
- GREEN: added `Temporalio::Exception::ReadOnly` (the sdk-python ReadOnlyContextError analog); `_assert_writable` now throws it; added head asserts to `patched` (before memoization), `_signal_child_workflow`, `_signal_external_workflow`, `_request_cancel_external_workflow` (each before seq allocation so a violation leaves no stale state); `_apply_query_workflow` runs the handler under `dynamically $read_only_depth + 1`.
- REFACTOR: `_run_update_validator` discriminates the violation by `isa('Temporalio::Exception::ReadOnly')` instead of the fragile message-regex; both read-only scopes (query + validator) gained a command-leak backstop that snapshots the command count, strips anything an unguarded API buffered, and raises/routes the typed error, so NEW command-emitting APIs inherit the guard even without a per-site assert.
`_assert_writable`'s comment now carries the guarded-surface table (the R24 table) citing R8 and the sdk-python parity sites.
- Verify: `prove -lj4 t` green (144 files, 660 tests, integration live against the dev server; up 8 subtests), `prove -lj4 xt` green (318, up 2 for the new module's POD). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (R24) | Full RED/GREEN/REFACTOR for the uniform read-only guard (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Reading the Python call-site list first fixed the action labels and the query-death routing (query failure, not task failure) before the test was written; RED failed exactly as predicted.
- Grepping for consumers of the old "read-only context" message before retyping the error found the single regex in `_run_update_validator` and confirmed updates.t asserts only the completion status, so the retype was safe.

**What could improve:**
- Nothing notable; the plan's file paths were accurate (line numbers had drifted slightly from earlier remediation commits, as expected).

**Course corrections:**
- None.

## Process Improvements

- When a plan step says "the typed error" but the existing code throws the base class with a message regex downstream, budget for the retype: find every consumer of the message text first, then introduce the subclass and switch consumers to isa checks in the same commit.

## Observations

- The cancel hooks on child/activity/timer/nexus handles push commands from inside `Future->on_cancel` callbacks shared with eviction sweeps; they were deliberately left unguarded at the site, but the new leak backstop still catches a query handler that cancels a stored future (the leaked cancel command is stripped and the query fails typed), which matches Python's guarded `cancel activity handle` behavior without touching the eviction path.
- `Temporalio::Exception::ReadOnly` surfaces on the wire as ApplicationFailureInfo with the full class name as `type` (the converter's generic-Temporalio-exception arm), which is what the replay test asserts.
- Next unchecked step is R20 (isolate exceptions per entry in the callback drain loop, Core/Callback.pm drain sites).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R20 is the bridge completion drain loop; the blast-radius contract for callback isolation mirrors how other SDKs guard their completion dispatch.
