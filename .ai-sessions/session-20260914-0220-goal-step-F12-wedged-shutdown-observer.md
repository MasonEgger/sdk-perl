# Session Summary: Observe the Real Run Future on a Wedged Shutdown (F12)

**Date**: 2026-09-14
**Duration**: single step, three dispatch modes plus a two-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F12, plan.md Section 6 Step F12 (Keep the Real Run Future Alive and Observed on a Wedged Shutdown), GitHub #5 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F12, all 8 plan sub-steps)

## The Gap

The Fable review of e51e761, which landed the I5 shield on `Temporalio::Test::Worker::shutdown`, raised five warns against what that commit left behind.

The wedge test proved the diagnostic but not the shield.
`sdk/t/unit/test_worker_shutdown.t` asserted only that a stalled drain raises `worker run did not drain within ${timeout}s`, and a fix that kept an unshielded race and merely widened the guard to spot `wait_any`'s loser-cancel would raise that exact message while tearing the live worker down.
Nothing in the file looked at the real run future.

The abandoned run future had no continuation.
On the timeout branch `shutdown` walked away from a pending future belonging to a worker that was still up, and the worker's runtime can fail the still-undrained poll futures a moment after the die.

The contract comment claimed too much.
It promised "no orphaned processes" for `shutdown` as a whole, but the timeout branch deliberately skips finalize and the fork-pool close, so the promise held on the clean drain only.

The `await_result` POD was wrong.
It said "Async. Returns a Future resolving once the worker's run loop has finished", and the method is synchronous: it blocks the loop and returns the resolved value.

The todo.md line for the I5 REFACTOR sub-step carried muddled wording ("one arm each vs. two") for a comparison between a two-arm and a three-arm race.

## The Fix

`shutdown`'s timeout branch now attaches an observer to the real run future before it raises.

The continuation ignores a done or cancelled outcome and, on a failure, emits `warn "worker run loop failed after the drain timeout: $failure\n"`.
Plain `warn`, not a Test2 diag: `Temporalio::Test::Worker` carries no Test2 dependency and non-Test2 consumers load it.
The run future is still left pending and uncancelled, so the live worker is not ripped out from under the caller.

The contract comment is now qualified.
"No orphaned processes" is stated as a guarantee of the clean drain only, and the timeout branch is documented as leaving the worker un-finalized and the fork pool un-closed, because finalizing would block on the very poll that failed to drain.
Tearing that state down after a wedge is the caller's job, typically an `END` block.

The `shutdown` POD gained a paragraph stating what each branch promises, including the new late-failure warning and why it is needed: without it the failure is swallowed silently by the cancellation shield, whose own callback retrieves it into a proxy `Future` the race discarded.

`await_result`'s POD is rewritten as synchronous, with a two-line usage synopsis, the concurrent-poll-loop guarantee, the crash-surfaces-at-once behavior, and the `future did not resolve within ${timeout}s` timeout message.

todo.md line 44 now reads "two-arm vs three-arm".

## The Tests

Subtest 1 gained the shield assertion the review asked for: after the drain-timeout `like`, two checks that `$worker->{run_future}` is neither ready nor cancelled.
Proven RED against the exact wrong fix, not against a strawman: dropping `without_cancel` from `shutdown` turns those two RED while the diagnostic `like` above them still passes, which is precisely the false pass the review predicted.

Two new subtests cover the cases the existing synchronous fakes cannot reach, because subtests 2 and 3 settle the run future inside `shutdown` before the race is even built.

Fail-during-race settles from `$loop->later` so the failure lands while `wait_any` is pending, and asserts the `worker run loop failed during shutdown: mid-race boom` diagnostic is re-raised rather than swallowed by the shield.

Fail-after-timeout wedges the drain, catches the die, then fails the run future inside a plain block localizing `$SIG{__WARN__}`, and asserts the harness's own late-failure warning was captured.
The localization is inside a plain block and never crosses an await, per spec 16.1.

## The Corrected Premise

The plan's sub-step 1 asked for a NEGATIVE assertion: that the retrieved late failure emits no "lost a failed Future" warning, and that this fails today.
That assertion cannot be made RED, and a scratch probe against Future 0.52 (Future::PP) shows why.

`without_cancel` registers its own `on_ready` on the ORIGINAL future, and `Future::PP::_mark_ready` sets `{reported} = 1` as soon as any CB_FAIL callback runs.
On HEAD the run future was therefore already flagged reported the instant it failed, so the abandoned-Future warning never fired for it.
That warning is also gated behind `PERL_FUTURE_DEBUG=1`, which the suite never sets, so the negative check would have passed by construction in two independent ways.

The subtest asserts the positive signal instead: the harness's own warning fires.
That is genuinely RED on HEAD and pins an observable behavior rather than a Future-internal flag.

The four abandoned failed futures visible under `PERL_FUTURE_DEBUG=1` were re-attributed during validation.
All four are `wait_any` convergent futures (IO::Async::Future, the highest subclass among the race components), one per wedged-drain race the file runs.
Neither the run future nor `$loop->timeout_future` is among them, since `wait_any`'s own callback marks the timeout future reported.
The count is identical on HEAD and after this change.

## Harness Comparison

Neither reference harness bounds the drain, so neither faces this question.
sdk-python awaits `worker.shutdown()` and then the run task with no timeout (`tests/helpers/worker.py`).
sdk-ruby joins inside a block-scoped `worker.run do` (`test/workflow_utils.rb`).
The bound is this harness's own addition, which makes diagnosing a wedge its own responsibility; that reasoning is recorded in the `shutdown` contract comment.

## Deviations from Plan

- Plan said: the late-failure subtest asserts no "lost a failed Future" warning is emitted, and this FAILS on HEAD.
- Deviated: that literal assertion cannot be made RED, so the subtest asserts the positive signal instead (the harness's own late-failure warning fires), keeping the no-abandoned-warning check as a regression guard.
  Reason, verified empirically with a scratch probe against Future 0.52 (Future::PP): `without_cancel` registers its own `on_ready` on the ORIGINAL future, and `Future::PP::_mark_ready` sets `{reported} = 1` as soon as any CB_FAIL callback runs, so on HEAD the run future is already flagged reported and the DESTROY warning never fires.
  That warning is also gated behind `PERL_FUTURE_DEBUG=1`, which the suite never sets.
- Impact: none on the requirement.
  The new subtest is genuinely RED on HEAD and pins an observable behavior (the emitted diagnostic) rather than a Future-internal flag.

- Plan said: the GREEN continuation "diags" a late failure.
- Deviated: used plain `warn`, not a Test2 diag.
  `Temporalio::Test::Worker` carries no Test2 dependency and is loaded by non-Test2 consumers.
- Impact: the late-failure notice lands on STDERR rather than through the Test2 formatter; the test captures it with `local $SIG{__WARN__}` inside a plain block, exactly as the step prescribed.

- Plan said: todo.md "line 45" carries the muddled I5 REFACTOR wording.
- Deviated: the line is 44, not 45.
  Edited by content match rather than by line number.
- Impact: none.

### Observation, deliberately NOT fixed (out of F12 scope)

Under `PERL_FUTURE_DEBUG=1` the shutdown race leaves four abandoned failed futures.
Corrected attribution (validator probe, iter 1): all four are `wait_any` convergent futures, one per wedged-drain race the file runs.
Neither the run future nor `$loop->timeout_future` is among them; `wait_any`'s own callback marks the timeout future reported.
The count is identical on HEAD and after this change.
Fixing it would mean the same treatment at every `wait_any` site including `await_result`, which F12 does not ask for.
Worth a follow-up issue if the abandoned-future noise ever matters.

### Fix-loop iter 1

Validator verdict `warn`: one warn and one info, both applied.

- `code-style.comment-accuracy` (warn, `Worker.pm:239`), applied.
  The observer comment claimed an unobserved late failure would surface as an abandoned failed Future at global destruction.
  The probe recorded above shows the opposite: `without_cancel`'s callback on the original future marks it reported the instant it fails, so nothing warns, not even under `PERL_FUTURE_DEBUG`.
  The comment now says the failure is swallowed silently and the continuation is the only thing that reports it, and the `shutdown` POD sentence was realigned to the same mechanism.
- `code-style.test-behavior` (info, `test_worker_shutdown.t:136`), applied on orchestrator instruction.
  Dropped the "not abandoned as an unreported failed Future" guard: the abandoned-Future text is emitted from DESTROY, after the block localizing `$SIG{__WARN__}` has exited, so the assertion passed by construction.
  The positive harness-warning check is the real pin; a comment sentence now records why the negative counterpart is not worth having.

### Fix-loop iter 2

Validator verdict `clean`, with one info finding carried into the commit body (the deferred idempotency follow-up) and one wording note applied during finalize.
The test comment at `test_worker_shutdown.t:124` said an unobserved late failure is "retrieved by nobody", which contradicts `Worker.pm`'s own corrected comment explaining that the shield's proxy callback does retrieve it.
The phrase is now "reported nowhere".

### Deferred follow-up

A second `shutdown` call after a wedge attaches a second `on_ready` observer, so one late run-loop failure would warn twice.
The die behavior stays idempotent, and a once-only field (`field $late_observer_attached` plus a guard) would close it.
That is past the budget this step allowed and is left as a follow-up.

## Key Actions

- Added the shield assertion to `sdk/t/unit/test_worker_shutdown.t` subtest 1: the real run future is neither ready nor cancelled after a drain timeout, proven RED by dropping `without_cancel` while the diagnostic `like` still passes.
- Added a fail-during-race subtest that settles from `$loop->later` so the failure lands while `wait_any` is pending, and asserts the loop-failed diagnostic is re-raised.
- Added a fail-after-timeout subtest that pins the harness's own late-failure warning, captured with `local $SIG{__WARN__}` inside a plain block.
- Attached an `on_ready` observer to the real run future on the timeout branch before the die, emitting `worker run loop failed after the drain timeout: ...` on a late failure.
- Qualified the `shutdown` contract comment so "no orphaned processes" holds on a clean drain only, and recorded the sdk-python and sdk-ruby comparison in it.
- Corrected the `await_result` POD from async to synchronous and documented the `shutdown` timeout branch's guarantees.
- Aligned todo.md line 44 to "two-arm vs three-arm".

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F12 implement) | Executed plan.md Section 6 Step F12 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: one warn, one info |
| Executor `mode=fix`, iter 1 | Corrected the observer comment and the matching POD sentence, dropped the vacuous negative guard | Applied 2, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean`, one info finding plus a comment wording note |
| Executor `mode=finalize` | Wording fix, session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Proving RED against the exact wrong fix (drop `without_cancel`, keep everything else) rather than against a deleted feature is what makes the shield assertion worth having.
  The diagnostic `like` stays green under that mutation, which is the false pass the review predicted.
- Running a scratch probe against the installed Future before accepting the plan's premise caught an assertion that would have passed by construction in two independent ways.
- Settling the run future from `$loop->later` is the only way to reach the mid-race branch; the pre-existing synchronous fakes all settle before `wait_any` exists.

**What could improve:**

- The first GREEN comment explained the mechanism backwards (abandoned-Future warning at destruction) even though this step's own probe had already shown the opposite two sub-steps earlier.
  A finding proven in sub-step 1 has to be carried into the prose written in sub-step 3.
- The negative assertion survived into the implement pass as a "regression guard" after it was known to be unfalsifiable.
  An assertion that cannot fail is noise regardless of intent.

**Course corrections:**

- Replaced the plan's negative assertion with a positive one after the probe, and recorded why.
- Rewrote the observer comment and the `shutdown` POD in iter 1 to match the probed mechanism.

## Process Improvements

- Before writing a test that asserts the ABSENCE of a warning, confirm the warning can fire at all under the suite's environment.
  `PERL_FUTURE_DEBUG` gating and `{reported}` marking each independently suppress Future's abandoned-failure warning.
- When a step's early sub-step overturns a premise, grep the step's later prose for the old premise before finalizing.
- A `local $SIG{__WARN__}` block only captures warnings raised synchronously inside it.
  Anything emitted from DESTROY lands after the block exits and cannot be asserted on there.

## Observations

- F12 is the third follow-up in this section where the production behavior was mostly right and the test was the defect; here the shield worked but nothing held it in place.
- The cancellation shield has a second, non-obvious effect beyond keeping the future alive: it also marks the future reported, which turns a late failure from noisy into completely silent.
  That is the opposite of what the shield's original comment assumed.
- Both reference harnesses avoid this entire branch by not bounding the drain, which is worth remembering the next time a Perl-only convenience creates a Perl-only failure mode.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F13 concerns `result_type` reaching the data converter on update paths, which is Temporal payload-conversion semantics.
