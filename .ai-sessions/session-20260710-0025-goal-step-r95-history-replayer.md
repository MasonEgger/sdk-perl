# Session Summary: Step R95, From-History and Batch Replayer Surface

**Date**: 2026-07-10
**Duration**: ~35 minutes
**Conversation Turns**: 1 (autonomous dispatch)
**Estimated Cost**: medium (Python parity source reading, one full-suite run, one parser-bug probe cycle; no cargo)
**Model**: claude-fable-5

## Goal Context

- **Condition**: execute todo.md step R95 (real WorkflowHistory objects with from_json construction, batch replay of a stream with per-history results, nondeterminism as a per-history failure), one commit
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (R95.1 through R95.4 checked; full suite green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1

## Key Actions

- Read the R43 lesson (lessons.md 2026-07-09) and session summary first, as instructed: the c-bridge replay surface, the `original_execution_run_id` contract, the eviction-reason mapping, and the teardown order were all settled there, so R95 reduced to exactly the predicted three pieces (History-from-JSON, multi-push batching, a public result surface).
- Pinned parity against `../sdk-python`: `worker/_replayer.py:110` (replay_workflow), `:138` (replay_workflows), `:166` (workflow_replay_iterator, one bridge worker for N pushes), plus `client/_workflow.py:1683-1737` (WorkflowHistory, from_json/to_json/run_id) and `client/_helpers.py:43-105` (_history_from_json legacy-enum fix pass).
- RED: `sdk/t/replay/history_replayer.t` (honest RED: `Temporalio::Client::WorkflowHistory` absent). Six subtests: batch returns one result per history; a mutated history (recorded timer_id '2' vs the workflow's seq '1') fails ITS result with Nondeterminism while the valid one passes; replay_workflow single-history semantics; from_json/to_json byte-identical round trip replaying cleanly both ways; legacy UI/CLI pascal-case enum forms decode; typed argument strictness.
- GREEN part 1: new `sdk/lib/Temporalio/Client/WorkflowHistory.pm` (workflow_id + blessed events, run_id from the started attrs, to_json via the shared Protobuf::JSON codec, from_json accepting a string or hashref with the ported _fix_history_enum/_fix_history_failure pass, materialized via the decode(encode) round trip per the 2026-06-13 blessing lesson).
- GREEN part 2: `Test/WorkflowReplay.pm` refactor: the R43 replay_history guts became `_replay_session(\@items)` (one replay worker, per-item eviction future re-created before each push, keep buffers session-scoped, teardown on every exit path); `replay_history` delegates and keeps its contract; new `replay_workflow`/`replay_workflows` with `raise_on_replay_failure` defaulting to 1 (Python default).
- REFACTOR: `_eviction_failure` is the single shared reason-mapping (3 NONDETERMINISM -> exception object, 1/5 benign -> undef, else Runtime), comment cites parity audit worker finding 4 and the resolved from-history direction; README Replay section documents the new surface.
- Parser-bug detour: with Future::AsyncAwait merely LOADED, perl 5.38.2 failed to parse `field $history :param;` in a class following the main class ("Subroutine attributes must come before the signature"). Probes isolated the trigger to a `my sub name ()` inside a method (the R43 teardown) preceding a later class. Fix: Result/Results moved to their own file `Test/WorkflowReplay/Result.pm` (the Nexus OperationResult precedent). Lesson captured.
- Verify: core genuinely detected the mutation ("TMPRL1100 Nondeterminism error: Timer fired event did not have expected timer id 1, it was 2!"); `prove -lj4 t` green (195 files, 853 tests, live integration included); `prove -lj4 xt` green (439).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: R95, from-history + batch replayer | RED replay test, WorkflowHistory module, WorkflowReplay batch session refactor, Result wrappers, POD + README, todo check-off | Step complete, suites green, one commit |

## Efficiency Insights

**What went well:**
- Reading the R43 lesson and session summary before designing meant zero rediscovery of the bridge contracts; the step really was the predicted three pieces.
- The timer_id mutation proved out immediately as a per-history nondeterminism trigger, with core's own log line confirming the real comparison ran.

**What could improve:**
- The full xt run caught the multi-class parse failure only because pod-coverage requires every module fresh; a quick `perl -e 'require Future::AsyncAwait; require <module>'` smoke after adding a class to an existing file would have caught it before the xt cycle.

**Course corrections:**
- Result/Results started inline in WorkflowReplay.pm; moved to their own file after the pod-coverage failure exposed the my-sub-then-class parse trap.

## Process Improvements

- None.

## Observations

- Python's `WorkflowReplayResults` carries only `replay_failures`; the Perl `Results` also carries the per-history `results` list in push order as the synchronous stand-in for Python's async `workflow_replay_iterator`. Documented in POD as the resolved surface for the spec's "result per history" acceptance.
- `WorkflowHandle->fetch_history` (Python `_workflow.py:391`) is still absent; the fetched form is `WorkflowHistory->new(workflow_id => ..., events => ...)` over `fetch_history_events` output. Out of R95 scope, noted here in case a later parity pass wants it.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R96 (activity context logging details) pins against Python `activity.py:479-537`; the activity-context semantics ground truth helps.
