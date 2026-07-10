# Session Summary: R29 Break the Start-Future Ownership Cycle in Handles

**Date**: 2026-07-08
**Duration**: ~15 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one new unit test, one new Future method, two one-line resolve-site changes plus comments/POD; pure Perl, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R29 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R29, finding L5: handle start futures resolved with the owning handle formed an uncollectable cycle)

## Key Actions

- Root cause per finding L5: `ChildWorkflowHandle.pm:58` and `NexusOperationHandle.pm:64` resolved the start future with `$self`, so the future's stored result held the handle strongly while the handle held the future twice over (its `start_future` field AND the Runner-installed `on_cancel`/`on_signal` closures, which capture the futures lexically at the construction sites in `Runner::start_child_workflow` / `Runner::start_operation`).
The cycle pinned the handle, both futures, and everything the closures captured, once per child/nexus start.
- The fix takes the spec's weaken-the-back-reference arm, centralized as `Temporalio::Workflow::Future::done_weak($owner)`: resolve exactly as `->done`, then `Scalar::Util::weaken($self->{result}[0])`.
CPAN Future 0.52 here is the pure-Perl hash backend (`result` slot verified empirically); the poke is guarded on `reftype eq 'HASH'` plus slot presence, so an alternate backend or an already-cancelled future degrades to the old strong behaviour instead of crashing.
- Caller contract preserved: the future yields the handle for as long as any strong ref (the awaiting caller, the Runner's pending maps) keeps it alive; `->get` returns undef only once every strong ref is gone.
Both `_resolve_started` methods now call `done_weak`; a grep confirmed these were the only two future-resolves-with-owner sites, and the `done_weak` comment/POD flags the shape for any new site.
- RED evidence: new `sdk/t/unit/handle_start_cycle.t` mirrors the Runner construction (closures capturing the futures), resolves the start future, and asserts (weak-ref liveness) the handle is collected once caller refs drop while the start future still lives, plus a residual full-drop check.
Pre-fix all six cycle assertions failed for both handle classes; the callers-still-get-the-handle `ref_is` assertions passed before and after.
- The plan's cited Runner.pm:895-897 had drifted; the actual construction sites are `start_child_workflow` (~:962) and `start_operation` (~:1279), and the resolve sites are the two handle lines above. Test comments carry the corrected trace.
- Verify: `prove -lj4 t` green (148 files, 672 tests, integration live against the dev server), `prove -lj4 xt` green (318, POD coverage picks up the new `done_weak` =head2).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (step R29) | Full RED/GREEN/REFACTOR for the handle start-future cycle (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Probing Future 0.52's internals up front (one perl one-liner: Dumper of a done future plus a weaken/isweak check) settled the implementation question before any code was written.
- Reproducing BOTH ownership paths in the RED test (field and closure capture) meant the fix could not pass by accident with a field-only change.

**What could improve:**
- Nothing notable; the step was small and the probe path from the plan was already known-ephemeral from the R27 session.

**Course corrections:**
- First instinct was to weaken the handle's `start_future` field; that leaves the closure-capture cycle intact (the Runner hooks capture the futures lexically), which is why the fix targets the future's result slot instead.

## Process Improvements

- When breaking an ownership cycle, enumerate EVERY edge into the cycle before choosing which one to weaken; the obvious back-pointer (the field) was not the only strong path here.

## Observations

- `done_weak` is now the pinned single exchange point for any future that resolves with its owner; the POD says new sites must use it, never `->done`.
- Next unchecked step is R31 (honor pending futures from custom slot suppliers in `Worker/SlotSupplierRegistry.pm::_resolve_permit`; unit test, finding L19).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R31 touches worker slot suppliers; the worker-tuning semantics frame what a pending reserve future must mean for permit issuance.
