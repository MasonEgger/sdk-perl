# Session Summary: Drain a Dead Poll Loop Until Core Shuts Down (F3)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a one-iteration fix loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor dispatches), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F3, plan.md Section 6 Step F3 (Drain a Dead Poll Loop Until Core Shuts Down), GitHub #3 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F3, all 8 plan sub-steps)

## The Defect

The Fable review of c6677f0 (the I3 fix) found the unwind only half finished.
I3 taught `Worker::run` to race the poll loops to the first failure instead of gathering all of them, which stops a fatal death from hanging behind a healthy sibling long-polling an idle queue.
But the loop that failed has stopped polling ITS kind for good, and core's shutdown will not finish while that kind is still owed replies.

`Worker::shutdown` on the core side (`../sdk-rust crates/sdk-core/src/worker/mod.rs:967-1000`) waits for `workflows.shutdown()` to see every pending eviction both POLLED and REPLIED TO (this SDK never sets `ignore_evicts_on_shutdown`), and for `at_task_mgr::shutdown()` to see every in-flight activity body settle.
So a dead workflow loop with an eviction owed, or a dead activity loop with a body in flight, leaves core waiting on a reply nobody will ever send, and `_finalize_and_free` is what waits on core.
sdk-python covers the same ground by swapping each failed poller's task for `drain_poll_queue` (`../sdk-python worker/_worker.py:843-846`) and by awaiting `wait_all_completed` (`:869`) before `finalize_shutdown` (`:875`).

## The Fix

- `Worker::_drain_poll_queue($kind)` polls ONE kind through the same bridge call its `PollLoop` was driving (`_drain_poll`) and answers each task with a failed completion (`_drain_complete`) until the poll returns the undef ShutDown sentinel.
  The failure message is the reference SDKs' exact string, `Worker shutting down` (`_activity.py:198`, `_workflow.py:239`, `_nexus.py:206`), and each kind's completion is their exact shape.
- A `field %drain_started` guard makes the drain at most once per kind, ever.
  The guard keys on the KIND rather than the `PollLoop` object because the queue belongs to core, not to whichever object happened to be reading it.
- `run()` keeps its loops PAIRED with their kind and their `PollLoop` object, so the fatal path can tell a dead loop from a survivor, pick the right drain arm, and reach the dispatches the dead loop abandoned.
  Only dead loops get drained; a survivor is still polling and would race the drain for the same queue.
- `PollLoop::drain_in_flight` returns a Future over the loop's `@in_flight` dispatches.
  `run()` already awaits those on the exit paths it controls, but a poll source that DIES throws straight out of the while loop and leaves them un-awaited, and they are cancelled the moment the `PollLoop` goes out of scope.
  `run()` awaits it for every loop before `_finalize_and_free`, matching Python's unconditional `wait_all_completed` in the same slot.
- The original poll-loop error stays the raised error on every path; finalize failures still attach as secondary.
  A drain that dies is warned about (`Temporalio::Worker: <kind> drain died: <err>`) and then swallowed, so it can never displace the error being unwound while still saying why finalize might now wedge.
  Python drops this one silently.
- `Worker::run`'s POD gained a five-step ordered account of the fatal unwind, and `PollLoop`'s POD documents `drain_in_flight` and the poll-source-death case it exists for.

## The Reproduction Finding

The plan asked for a RED integration reproduction built on a CACHED run, expecting it to WEDGE pre-fix.
It does not wedge against the pinned core (temporal CLI 1.6.2, server 1.30.2), and a probe showed why: core's `shutdown_done` counts a run as pending work only when it has an outstanding task, activation, or buffered task, or has `trying_to_evict` set.
An IDLE cached run owes no eviction round trip at shutdown, so there is nothing for the dead loop to fail to answer.

Scenario 2 was rebuilt on `max_cached_workflows => 0`, which makes core queue an eviction the instant a workflow task completes.
That eviction is genuinely never answered pre-fix: the run sends exactly one workflow completion, and core's workflow-processing thread panics with `Activation processor channel not dropped`.
The RED signal is therefore a completion-count assertion, not a timeout.

Scenario 3 (activity body in flight) also PASSED pre-fix, because Perl's orphaned in-flight dispatches keep running on the IO loop while `_finalize_and_free` awaits core, so the completion core is waiting on still lands.
Both non-wedging scenarios are kept as regression guards on the unwind, and all three stay under the subprocess guard because scenario 1 does hang pre-fix and any of the three could hang on a regression.

## The Nexus Divergence

The nexus drain completes a `CancelNexusTask` with the CANCEL's own `task_token`.
Python reads `task.task.task_token` unconditionally (`_nexus.py:203-207`), which answers a cancel variant with an empty token; `nexus.proto:43-59` defines `NexusTask` as a oneof whose `cancel_task` carries its own token.
This is a deliberate divergence, pinned by a unit subtest that drives both oneof variants.

## The Tests

`sdk/t/unit/fatal_poll_unwind.t` grew from the I3 race subtests to ten, all against a fake core:

- Per-kind drains for activity, workflow, and nexus, each asserting the completion shape, the message, and the token or run_id echo.
- The nexus subtest covers BOTH oneof variants and pins the cancel-token divergence.
- The per-kind guard: a second drain for the same kind polls nothing.
- `PollLoop::drain_in_flight` awaits dispatches left running when the poll source dies.
- Two loops failing in the same tick: one drain per kind, a single raised error.
- A drain that dies is warned about and never displaces the loop error.

`sdk/t/integration/fatal_poll_unwind.t` carries three live subprocess-guarded scenarios (activity-loop death against an idle workflow long-poll; workflow-loop death with an eviction owed; activity-loop death with a sync body in flight).
`sdk/t/integration/worker_on_fatal_error.t` gained a comment recording that its stderr drain-death line is expected output.

Full suite: 930 tests / 212 files, green. Author suite: 474 tests / 8 files, green.

## Deviations from Plan

- Plan said: the RED integration reproduction is a workflow-poll failure injected once a run is CACHED, and it should WEDGE today (run() never returning, caught by the harness ceiling).
- Deviated: it does not wedge against the pinned core (temporal CLI 1.6.2 / server 1.30.2). Two reasons, both verified by probe: core's `shutdown_done` only treats a run as pending work when it has an outstanding WFT/activation/buffered task or `trying_to_evict` set, so an IDLE cached run needs no eviction round trip at shutdown; and Perl's orphaned in-flight dispatches keep running on the IO loop while `_finalize_and_free` awaits core, so the completion core is waiting on still lands. The cached-run and in-flight-activity scenarios both PASSED pre-fix. Replaced the cached-run scenario with a `max_cached_workflows => 0` variant, which makes core queue an eviction the instant a workflow task completes; that eviction is genuinely never answered pre-fix (exactly one workflow completion sent, and core's workflow-processing thread panics with "Activation processor channel not dropped"). The RED signal is therefore a completion-count assertion, not a timeout. Observed behavior is recorded in the test's scenario-2 comment as the plan asked.
- Impact: the F3 drain is still exercised end to end live, and the two non-wedging scenarios are kept as regression guards on the unwind (they must keep passing). The deterministic per-kind drain contract (two tasks answered, message, token/run_id echo, sentinel stop, one-drain-per-kind guard, two-loops-in-one-tick) is proven in sdk/t/unit/fatal_poll_unwind.t against a fake core rather than live.

### Fix-loop iter 1

- Plan said: n/a (validator findings applied after the implement dispatch).
- Deviated: applied the one warn and both infos from the iter-1 findings block.
  (1) `record.claims-must-be-true`: the integration test's header claimed scenarios 2 and 3 both hang pre-fix. Reworded the trailing header paragraph and ABOUTME lines 6-7 to match what was actually observed.
  (2) `observability.silent-swallow`: run()'s drain `->else` now warns before swallowing, so a drain that stops early cannot wedge finalize silently.
  (3) `tests.untested-branch`: added a nexus drain subtest covering BOTH NexusTask oneof variants.
- Impact: `patch_kind` in the unit test grew a `fail_at => { N => $err }` option so the DRAIN's own poll can be made to die. Both new subtests were confirmed RED-capable by temporary break: reading `$task->task->task_token` unconditionally fails the nexus subtest (3 assertions), and restoring the bare `->else` fails the drain-death subtest (2 assertions). The new warning also fires in t/integration/worker_on_fatal_error.t, whose poll wrapper stays armed and kills the drain's own poll; that test now carries a comment saying the stderr line is expected output rather than a regression.

### Fix-loop iter 2

- The validator returned clean with two infos (the benign drain death in `worker_on_fatal_error.t`, and the pinned nexus cancel-token divergence) plus one trivial wording request: the integration header still stated the cached-run wedge as observed FACT while the same header's scenario notes said neither scenario hangs.
- Applied at finalize: both test files now say core is "left waiting on a reply the dead loop will never send" (core's contract) instead of asserting a hang, and the stale `lessons.md line 14` pointer (that entry records the never-started-poller finalize deadlock, a different failure) is dropped from both.

## Key Actions

- Read the Fable review block on c6677f0 and the Python drain contract at `_worker.py:841-875`, then traced core's `shutdown_done` to find what actually counts as pending work.
- Built the per-kind drain, the `%drain_started` guard, `PollLoop::drain_in_flight`, and the ordered fatal unwind in `run()`.
- Probed the pinned core twice to falsify the plan's cached-run hypothesis before rewriting scenario 2 on a zero-size cache.
- Applied one warn and four infos across two validator iterations.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F3 implement) | Executed plan.md Section 6 Step F3 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: one claims-must-be-true, two infos |
| Executor `mode=fix`, iter 1 | Reworded the test header, warned before swallowing a drain death, added the nexus oneof subtest | Applied 3, deferred 0, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean` with two infos and a wording nit |
| Executor `mode=finalize` | Wording fix, session summary, lesson, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Probing core's `shutdown_done` before trying to force a hang turned a would-be flaky timeout test into a deterministic completion-count assertion.
- Both fix-loop subtests were proven RED-capable by temporary break before being kept, so neither is a vacuous green.

**What could improve:**

- The plan's RED hypothesis ("a cached run wedges shutdown") was carried into the spec text and into two test-file comments before anyone checked it against core. One probe up front would have saved the rewrite and the two validator wording findings that followed it.

**Course corrections:**

- Scenario 2 moved from a cached run to `max_cached_workflows => 0` mid-implement, and the RED signal moved from a timeout to a completion count.

## Process Improvements

- When a plan step asserts a specific deadlock as its RED, verify the deadlock's precondition against the dependency's source before writing the test around it.
- A comment that states an unverified mechanism as fact will come back as a validator finding. Write what the dependency's contract says, and reserve the factual voice for what the run actually did.

## Observations

- The same pre-fix run that "passes" scenario 3 leaves core's workflow-processing thread panicking in scenario 2. A green Perl-side assertion is not evidence that core is healthy; the panic only surfaced by reading core's stderr.
- Every reference SDK writes the literal string `Worker shutting down` for this failure, which makes it a MUST-match constant rather than a message choice.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F4 is the two-classes canary, still SDK-internal, and the next steps after it touch workflow-facing behavior.
