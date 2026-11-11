# Session Summary: Fail the Workflow Task or Execution When a Sync :Signal Handler Dies (I2)

**Date**: 2026-09-13
**Duration**: single-step finalize dispatch (implement + fix work happened in prior dispatches this run)
**Conversation Turns**: n/a (subagent finalize dispatch; no direct user turns)
**Estimated Cost**: n/a
**Model**: claude-sonnet-5

## Goal Context

- **Condition**: close out `/bpe:goal` Section 1 of `todo.md`, Step I2 ("Fail the Workflow Task When a Sync :Signal Handler Dies"), requirement I2 in `spec.md`, GitHub issue #2.
- **Mode**: step
- **Outcome**: converged (this dispatch performs the commit transaction after the validator cleared the work at iter 3)
- **Turn count**: unknown (multi-dispatch orchestrator loop; this is the finalize leg)
- **Subagent dispatches**: at least 3 for this step (implement, fix iter 1, fix iter 2, validator iters 1-3) plus this finalize
- **Steps completed**: 1 of 1 (todo.md item I2, all 8 sub-steps checked)

## Key Actions

- Fixed the silent-failure bug in `Runner.pm`'s `_dispatch_signal`: a synchronous `:Signal` handler that died produced an already-failed Future that was never tracked in `%in_progress_handlers` and never observed, so the activation silently completed as if nothing happened.
- Added `_settle_signal($future)`, a single shared sink both the sync (already-ready) and async (tracked) signal arms funnel through. It classifies a handler die exactly like the main `:Run` body's own die (`_outcome_for_failure` / `_is_workflow_failure_exception`): a `Temporalio::Exception::*` (or a class listed in `workflow_failure_exception_types`) fails the workflow EXECUTION via `_workflow_failed_completion`; any other die (plain or foreign) fails the workflow TASK via `$current_activation_error`. A cancelled handler future (eviction sweep) is dropped with no activation error.
- Corrected the original one-way framing: the iter-1 validator pass and an early implementation draft routed every signal-handler die to task failure. The iter-2 validator caught the asymmetry against sdk-python's `_run_top_level_workflow_function` (`worker/_workflow_instance.py:2518-2565`), which classifies via `workflow_is_failure_exception` before choosing `_set_workflow_failure` vs. `_current_activation_error`. The two-way classification was then implemented and the Runner.pm POD outcome-decision table (the `_outcome_for_failure`/`FailWorkflowExecution`/task-failure bullets) was corrected to state the signal-handler case explicitly instead of contradicting the code.
- Added three one-class-per-file fixtures under `sdk/t/lib/WfDef/`: `DyingSignal.pm` (sync handler, plain die, expects task failure), `DyingAsyncSignal.pm` (async handler, awaits then dies, expects task failure via the tracked/`%in_progress_handlers` arm), `DyingSignalFailure.pm` (sync handler throws `Temporalio::Exception::Application`, expects `FailWorkflowExecution`).
- Added `sdk/t/replay/signal_handler_die.t` covering all three fixtures.
- Rewrote spec.md's I2 "Required behavior" and "Acceptance" to state the two-way classification rule and the sdk-python file:line citation, and to require both a plain-die replay assertion and a Temporal-failure-type replay assertion.
- Validator history for this step: iter-1 warn (one-way classification, plus an info note about stale sdk-python line anchors in `DyingSignal.pm`); iter-2 block (the Runner.pm POD outcome table still described the old one-way behavior, contradicting the corrected code); iter-3 clean.
- Final verification before commit: full suite `( cd sdk && PERL5LIB=... prove -lj4 t )` ran 198 files / 862 tests, PASS; author suite `( cd sdk && PERL5LIB=... prove -lj4 xt )` ran 8 files / 462 tests, PASS.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Mode: finalize dispatch for Step I2 | Ran final test suites, wrote this session summary, generated commit message, staged the step's files, committed and pushed | Clean tree, one commit, one push |

## Efficiency Insights

**What went well:**
- The shared `_settle_signal` sink kept the sync and async arms from diverging in behavior, which made the iter-2 fix (adding the execution-failure branch) a localized change instead of a two-place patch.
- Mirroring the exact classification logic already proven correct for the `:Run` body (`_outcome_for_failure`) avoided inventing a new decision rule from scratch.

**What could improve:**
- The first implementation pass should have checked sdk-python's `_run_top_level_workflow_function` classification (not just "does Python fail the task on a signal die") before writing the fixture and test; that earlier check would have caught the one-way/two-way asymmetry before iter-1 instead of after.

**Course corrections:**
- iter-1 to iter-2: added the `DyingSignalFailure.pm` fixture and the FailWorkflowExecution branch in `_settle_signal` after the validator flagged the missing execution-failure classification.
- iter-2 to iter-3: corrected the Runner.pm POD table, which still described the pre-fix one-way behavior after the code was already two-way.

## Process Improvements

- When a bug fix mirrors an existing, already-correct code path (here, `_outcome_for_failure` for the `:Run` body), grep for and read that path's sdk-python analog BEFORE writing the fixture, not after the first validator round.

## Observations

- This is a good instance of the "die-to-failed-completion funnel" pattern (R11) being extended to a new call site (signal handlers) rather than reinvented; the funnel abstraction paid for itself here.

## Suggested Skills for Next Session

- None specific; the next todo.md item (Step I3, unwinding `Worker::run` on a fatal poll-loop death) is pure Perl/IO::Async work already covered by this project's CLAUDE.md conventions.
