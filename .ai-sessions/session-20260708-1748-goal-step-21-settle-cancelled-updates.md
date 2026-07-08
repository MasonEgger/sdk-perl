# Session Summary: R17 Settle Updates from Cancelled Handler Futures

**Date**: 2026-07-08
**Duration**: ~30 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one fixture, two new test files, one Runner.pm method split, two full-suite runs, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R17 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R17, finding L7: evicting a run with an in-flight async :Update croaked in _settle_update)

## Key Actions

- Re-ran the L7 probe inline (the step-45 `verify-45/` scratch dir is gone): a cancelled Future is ready, reports `is_cancelled`, passes `->failure` EMPTY, and `->result` croaks "was cancelled"; that state table is now embedded in both new test files and the Runner comment.
- RED discovered the fixture shape is load-bearing: the planned wait_condition-parked handler (WfDef::UpdateParker) never reaches the cancelled state, because Future::AsyncAwait clones the handler's method future from the first-awaited `_ConditionFuture`, whose cancel override FAILS the clone with Cancelled instead.
Created `WfDef::PlainFutureUpdater` (the update analog of R9's PlainFutureParker, parked on a plain `Temporalio::Workflow::Future`) so evict's `%in_progress_handlers` sweep natively cancels the handler future; pre-fix the eviction activation then died at exactly `Runner.pm:2851` `->result` "was cancelled" with no eviction completion sent.
- RED files: `sdk/t/replay/evict_pending_update.t` (dispatcher-driven, mirrors evict-sibling-delete.t: accepted-in-flight update, then remove_from_cache; asserts no croak, runner dropped, empty-success eviction completion SENT) and `sdk/t/unit/settle_update_states.t` (drives the factored settle core across done, failed-Temporal, failed-plain, and cancelled futures, plus a live probe subtest pinning the cancelled state table).
- GREEN+REFACTOR in one motion per the plan: `_settle_update` classification factored into `_update_settlement`, which discriminates `->is_cancelled` FIRST and returns `{ dropped => 1 }`; `_settle_update` maps dropped to no command and no activation error.
Drop (not reject) is the verified Python eviction contract: `../sdk-python/temporalio/worker/_workflow_instance.py` run_update swallows the teardown exception under `self._deleting` with no response, while a non-eviction task-cancel becomes a Temporal CancelledError and takes the rejected branch (which in Perl arrives as a FAILED future via the B3 throw-into-handler cancel chain, so it already worked).
- Verify: both new files green; `prove -lj4 t` green (142 files, 646 tests, integration live against the dev server); `prove -lj4 xt` green (314; `_update_settlement` is underscore-private so Pod::Coverage wanted nothing). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R17 (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Running the three-state Future probe as a one-liner before writing any test pinned the exact croak signature and made the RED assertion precise ("was cancelled" at the `->result` line).
- The R16 test (evict-sibling-delete.t) was a drop-in template for asserting the eviction completion is actually SENT, not just that evict lives.

**What could improve:**
- The first RED fixture (UpdateParker) exercised a DIFFERENT defect than L7; probing the future class chain earlier (AWAIT_CLONE of the first-awaited future) would have picked the right fixture on the first try. The lesson from step 17 (R8/R9) described this exact mechanism for the main run future; I should have applied it to handler futures before writing the fixture.

**Course corrections:**
- Swapped the replay fixture from WfDef::UpdateParker to the new WfDef::PlainFutureUpdater after the first RED run croaked via the clone double-fail instead of the L7 `->result` path.

## Process Improvements

- When a fix targets a specific Future STATE, verify the fixture actually produces that state before trusting the plan's suggested shape: print the tracked future's class and readiness in a scratch run, since subclass cancel overrides propagate through AWAIT_CLONE and dependent-future cloning.

## Observations

- **Candidate new finding (unfixed, out of R17 scope, no spec requirement covers it):** evicting a run whose async :Update handler is parked on `wait_condition` still croaks, via a different mechanism than L7. The handler's method future is an AWAIT_CLONE of `_ConditionFuture`, so evict's handler sweep `->cancel` runs the override and FAILS the clone with Cancelled; the conditions sweep then fails the REAL parked condition future, the resuming frame dies, and Future::AsyncAwait tries to `->fail` the already-failed method future: "Temporalio::Workflow::Runner::_ConditionFuture=HASH(...) is already failed and cannot be ->fail'ed at WfDef/UpdateParker.pm line 32", evict dies, no eviction completion. Repro: the original UpdateParker version of evict_pending_update.t (in this session's transcript). This is the handler-future sibling of findings R4/R4b and probably wants its own finding/step; flagging for triage rather than scope-creeping this commit.
- `_settle_update`'s rejected branch already handled the non-eviction cancel correctly because B3 made the workflow cancel chain THROW Cancelled into handlers (failed future) rather than natively cancel; only eviction produces the naked cancelled state.
- Next unchecked step is R23+R50 (shared cancellation future poisoned by wait_any loser sweep, plus direct Activity/ChildCancellation coverage).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R23+R50 concerns cancellation-future semantics; same workflow-semantics ground truth as this step.
