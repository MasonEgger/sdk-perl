# Session Summary: R11 Always Send a Completion for a Failed Activation

**Date**: 2026-07-08
**Duration**: ~35 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: moderate (one fixture, one replay file, one guarded live test, three lib edits, two full-suite runs, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R11 boxes complete, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R11, finding R5 / L9)

## Key Actions

- RED (`t/replay/failed_activation_completion.t` + `WfDef::PendingQuery`): rebuilt the vanished probe from the spec description: a `:Query` handler returning a pending `Temporalio::Workflow::Future`.
Three subtests: the Runner-level probe (process_activation must return a failed completion, not die), the same probe end to end through a WorkflowDispatcher with a completion collector, and a pre-runner dispatcher error (unregistered workflow type).
All three failed pre-fix with the predicted escapes.
- The actual croak differs from the plain-Future message: `Temporalio::Workflow::Future` croaks "is not yet complete and does not provide ->await" (at the pre-fix trace Runner.pm:2798 via `->result`), not "is not yet ready"; assertions match both shapes.
- RED (`t/unit/workflow_poll_loop.t`): a FailingDispatcherStub subtest asserts a failed dispatch FAILS `run()` with no warning; pre-fix `run()` resolved done and warned twice.
- RED (`t/integration/failed_activation_no_wedge.t`, SubprocessGuard, skip_all offline): live fault injection querying 'pending'; pre-fix the query hung the full 25s bound (the wedge, child exit 1); post-fix the query errors in ~5s carrying the croak message. sdk-core fails the legacy query when the activation completion is `failed` (verified in `sdk-core/src/worker/workflow/mod.rs` handle_activation_failed / ReportLegacyQueryFailure).
- GREEN (`Workflow/Runner.pm`): process_activation wraps job application AND `_build_completion` in try/catch; any escape maps to `_task_failed_completion`, the centralized funnel every verified trigger site (:2687, :2572, :1839, :1914, :2080, :2151, :2851) flows through, since all execute inside process_activation.
- GREEN (`Worker/WorkflowDispatcher.pm`): dispatch_task catch-all for pre/post-runner dies (codec decode, unregistered type, missing init job) building a failed completion via new `_failed_completion_for`, Python `_handle_activation` parity: non-retryable ApplicationError fails the WORKFLOW terminally (FailWorkflowExecution command), everything else fails the TASK; failure conversion guarded with the "Failed converting activation exception" fallback; codec-encode moved after the catch with its own "Failed encoding completion" replacement guard, so the send always runs.
- GREEN (`Worker/PollLoop.pm`): the warn-and-swallow `->else` is gone; dispatch failures are captured during reap and drain, and `run()` fails with the first one; Worker.run's existing wait_all + per-loop failure surfacing (previously dead code for dispatch errors) now carries it to the worker level.
- REFACTOR: R5/R11 comments at the funnel, the query `->result` trigger site, PollLoop, plus POD updates (dispatch failure semantics in PollLoop, a Failure catch-all bullet in WorkflowDispatcher, never-dies note on process_activation).
- Verify: new files green, full `prove -lj4 t` green twice (131 files, 615 tests), `prove -lj4 xt` green (314 tests). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R11 (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Checking sdk-core's `handle_activation_failed` before writing the live test settled what the client observes for a failed legacy-query activation (a prompt query error), so the live assertion was written once and passed on the first post-fix run.
- Bounding the live query await (25s) under the 90s SubprocessGuard made the pre-fix wedge a clean RED instead of a hang.

**What could improve:**
- The plan's Runner line numbers (from the step-45 audit) had drifted after the R8-R10 rewrite; grepping for the mechanism (the query `->result` read) beat trusting `:2807`-style anchors.

**Course corrections:**
- None; the two-layer design (Runner funnel + dispatcher catch-all) fell out of the RED tests directly, since the replay harness calls process_activation without a dispatcher.

## Process Improvements

- When a plan step asserts "a failed completion is sent", write the RED at BOTH the component that builds completions and the component that sends them; the harness-vs-dispatcher split surfaced immediately and shaped the fix correctly.

## Observations

- PollLoop is shared by the activity, workflow, and Nexus loops; all three dispatchers now own their die-to-completion mapping (ActivityDispatcher already did), so a failed dispatch future uniformly means a broken send contract and is worker-fatal at drain.
- The R13 step (keep query/update responses on failure completions) touches `_task_failed_completion`'s no-commands shape; the R11 funnel routes through it, so R13's change will automatically apply to escaped-die completions too.

## Suggested Skills for Next Session

- None beyond the standard BPE flow; the next step (R39, child-signal on_cancel hook) is a pure Runner.pm replay-tested change mirroring the external-signal arm.
