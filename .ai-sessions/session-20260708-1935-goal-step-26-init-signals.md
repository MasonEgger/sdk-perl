# Session Summary: R26 Init-Activation Signals Run Before the Main Routine

**Date**: 2026-07-08
**Duration**: ~30 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one new replay test + fixture, ordering change plus arrival-stamp bookkeeping in Runner.pm, two downstream test adjustments; pure Perl, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R26 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R26, finding R12: init-activation signals drained only after the :Run prologue, diverging from Python signal-with-start semantics)

## Key Actions

- Confirmed the Python ordering first, per the plan NOTE: `../sdk-python/temporalio/worker/_workflow_instance.py` `activate()` (:438-455) splits jobs into four sets (patches; signals+updates; other non-queries incl. initialize_workflow; queries) and pumps `_run_once` after each set (:461-471), and `_apply_signal_workflow` (:1057-1065) dispatches class-registered handlers immediately.
So an init-activation signal handler runs at least to its first await before the main routine's first statement; the test comment cites those lines.
- RED: new `sdk/t/replay/init_signal_ordering.t` + fixture `WfDef::InitSignalProbe` whose :Run FIRST statement snapshots handler-mutated state and returns synchronously.
Three arms: handler-visible-to-prologue, cross-name arrival order (note/mark/note), and a post-start regression arm on SignalGreeter.
Pre-fix the two ordering arms failed with 'empty' (prologue ran first); the regression arm passed.
- GREEN: `_apply_initialize` now drains buffered signals then buffered updates BEFORE kicking off the :Run body (both are Python set 1); previously the body was kicked off first.
The per-name `%buffered_signals` map also lost cross-name arrival order to hash order, so buffered entries now carry a monotonic arrival stamp and `_drain_buffered_signals` dispatches sorted by stamp.
- REFACTOR: the drain call site carries a named SIGNALS-BEFORE-MAIN comment citing R26/finding R12 and the Python lines; the process_activation ordering comment, `_apply_signal_workflow` header, and `_drain_buffered_signals` header were sharpened to the drains-before-body contract.
- Downstream fallout, both legitimate consequences of the corrected semantics and folded into the same commit:
  - `t/unit/worker_inbound_interceptor.t` pinned the old hook order (execute_workflow before handle_signal/handle_update on a combined activation); expectation updated to signal, update, execute_workflow, query.
  - `t/integration/repro_condition_timeout_rearm.t` (B10) failed live because `WfDef::DeadlineMover`'s run body clobbered `$deadline` that a `move` update landing in the init activation had already set; a stash experiment confirmed pre-change code passed. Fixture now uses `$deadline //= $wake_epoch;` (the Python defensive-init idiom for handler-shared state).
- Verify: `prove -lj4 t` green (146 files, 667 tests, integration live against the dev server), `prove -lj4 xt` green (318).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (R26) | Full RED/GREEN/REFACTOR for init-signal ordering (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Reading the Python `activate()` job-set split before writing the test produced the exact assertion (handlers before prologue, in arrival order) and the citation lines in one pass.
- The stash-run-unstash experiment on the failing integration test settled cause (my change vs. flake) in one 8-second run.

**What could improve:**
- The full-suite run surfaced the two downstream failures late; grepping tests for init-activation signal/update job combinations right after GREEN would have predicted both.

**Course corrections:**
- Initially considered scoping GREEN to signals only; moved the update drain too because Python's set 1 holds both and leaving updates after the prologue would create a new divergence.

## Process Improvements

- When a semantic ordering fix lands, sweep fixtures for run bodies that assign handler-shared fields from start arguments; each plain assignment is a latent clobber under handlers-before-main.

## Observations

- The B10 fixture failure is exactly the signal-with-start hazard Python documents: handlers may run before the main routine, so workflows must initialize handler-shared state defensively. Worth remembering for samples-perl.
- The cross-name arrival-order loss in the per-name buffer was invisible until now because the only multi-name init test (signals.t arrival-order subtest) happened to produce the same result under either hash order.
- Next unchecked step is R27+R38 (determinism-guard install point + override accountability; adapts `verify-45/runner-misc/probe_r13_compile_order.pl`, subprocess-guarded).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R27+R38 concerns the determinism guard (workflow-context time/rand trapping); the determinism reference frames what must be trapped and what must stay stock outside workflow context.
