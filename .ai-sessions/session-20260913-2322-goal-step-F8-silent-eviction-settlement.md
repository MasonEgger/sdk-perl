# Session Summary: Settle Handlers Silently During Eviction (F8)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a four-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F8, plan.md Section 6 Step F8 (Settle Handlers Silently During Eviction), GitHub #1 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (4), fix (3), finalize (1)
- **Steps completed**: 1 of 1 (F8, all 8 plan sub-steps)

## The Warns

All three came from the Fable review of 8e961d5, the I1 commit that reordered `evict`'s sweep so a condition-parked handler settles once instead of twice.

1. A condition-parked update or signal resumes with `Cancelled` during `evict`, and the update arm then ran the failure converter and pushed an `UpdateResponse` on a runner being torn down.
   A converter that dies there takes `evict` with it, so the `RemoveFromCache` completion is never sent.
   That is the same outward failure the I1 sweep reorder fixed, reachable by a second route the reorder did not close.
2. The `:Signal` twin of the parked-update case was asserted in comments and never tested.
3. The sweep-order rule that makes the reorder correct lived as a claim about an `AWAIT_CLONE` aliasing that does not exist, rather than as a stated invariant.

## The Fix

`_settle_update` now returns early under the `$evicting` latch, ahead of the call to `_update_settlement`.
No failure converter runs and no `UpdateResponse` is pushed during teardown, whatever the handler's outcome was.
The field is read directly instead of through `_classify_failure`, which is the route `_settle_signal` takes, because the classifier only ever sees a FAILURE value.
Eviction has to silence the completed arm too: a handler that RETURNED on the resuming frame would otherwise push an `UpdateResponse.completed` onto a dying runner, and a post-accept plain die would still record `$current_activation_error`.
The guard also has to sit ahead of `_update_settlement` rather than inside it, because the rejected arm is where the failure converter runs, and that call is the escape path the new test pins.
This matches sdk-python's `_deleting` swallow at `_workflow_instance.py:484-490`, with the same refusal stated at both layers there: `_add_command` raises `_WorkflowBeingEvictedError` while deleting (`:2076-2078`, `:2093-2095`), and `run_update`'s outer `except BaseException` returns under `self._deleting` (`:710-717`).

Two comment blocks were rewritten to describe the code as it now is.
The R17 comment on `_update_settlement` used to credit the eviction drop of the plain-future-park arm to its own `is_cancelled` guard; it now says both eviction arms are cut off upstream at the one early return, and that the guard is kept for the L7 direct-call contract (`t/unit/settle_update_states.t` calls the method directly with each of the three future states) and as defense in depth.
The `evict` header now states the sweep-order invariant once, in the form every list below it is ordered to satisfy: every awaitable class that overrides `cancel` to fail instead must be swept before the `%in_progress_handlers` pass, because those overrides resume the suspended frame and Future::AsyncAwait settles the handler's own return future as part of the same cancel.
The old `AWAIT_CLONE` wording was an overstatement and is gone: `AWAIT_CLONE` is `shift->new` (`Future.pm:232`), a fresh instance of the class, so a condition-parked handler's return future merely INHERITS `_ConditionFuture`'s fail-on-cancel override.
It is a separate object, not an alias, and that inherited override is the whole reason the order matters.

## Tests

`sdk/t/replay/evict_pending_update_wait_condition.t` went from 2 subtests to 5.

A new `TestFailureConverter::Dying` fixture proves a converter die is contained inside `evict()`.
Its `to_failure` bumps `$TestFailureConverter::Dying::CALLS` at the TOP, ahead of the die, and the test asserts the count is 0 after the eviction activation.
The count is what pins the claim: an implementation that still CALLED the converter but wrapped the call in an eval would keep the die-does-not-escape assertion green.
The converter is armed only across the eviction activation, so the accept path and the dispatcher's own failed-completion builder keep working.

`WfDef::UpdateParker` gained a `park_signal` `:Signal` handler, the condition-parked twin of `park`, which settles through `_settle_signal` rather than `_settle_update`.
It also gained `%WfDef::UpdateParker::CANCELS`, a resumption ledger keyed by handler name counting how many times a parked frame resumed with a `Temporalio::Exception::Cancelled`.
The ledger is the non-tautological half of every assertion in the file, because `_handle_eviction` sends its own fixed empty-success completion regardless of what `evict` did internally, so only an in-workflow counter can tell a single settle from the pre-fix double settle.
It reads park = 1, park_signal = 1, park_plain = 0: the two condition parks resume and unwind exactly once, while the plain-future park is natively cancelled and its frame is discarded rather than resumed.

The freed-runner subtest weakens a reference to the live runner and asserts it is gone once the eviction activation returns, with both condition-park sinks in the one run so the check covers the settlement closure F8 touched on each path.
Two ledger assertions sit beside it so the freed-runner check is provably non-vacuous.

## Two Follow-Ups (new GitHub issues, not in spec.md)

1. The missing "tasks remain" tripwire.
   sdk-python raises a `RuntimeError` after an eviction activation if `self._deleting and self._tasks`, with the stack traces of the surviving tasks (`../sdk-python/temporalio/worker/_workflow_instance.py:496-509`), because a task that outlives eviction is garbage collected later and the resulting `GeneratorExit` can wake its coroutine on a different thread.
   The Perl runner has no equivalent assertion: `evict` clears `%pending_activities`, `%pending_timers`, `%in_progress_handlers`, `%pending_child_workflows`, `%pending_external_signals`, `%pending_external_cancels`, `%pending_nexus_operations` and `@conditions` unconditionally at the end, so a future that was somehow never settled is dropped silently rather than reported.
   F8's weak-reference freed-runner assertion catches the refcount half of this class of bug, not the "a frame is still suspended" half.
   A Perl tripwire would have to count non-ready futures across those tables just before the clears and warn or croak.
2. A pre-existing leak: eviction does not free the `Temporalio::Workflow::Runner` of a run whose `:Update` handler is parked on a plain `Temporalio::Workflow::Future` (the R17 shape), while the same activation frees condition-parked update, condition-parked signal, and handler-free runs.
   Reproduce by driving `WfDef::UpdateParker`'s `park_plain` to accepted, weakening a reference to the runner, and dispatching a `RemoveFromCache` activation; the reference stays defined.
   Present on HEAD `4aaabc7`, so it predates F8.
   After that eviction the awaited plain future is released, `%in_progress_handlers` is cleared unconditionally (`Runner.pm:2320`), and the survivors are the runner at refcount 1 and the workflow instance.
   The `$settle`/`on_ready` closure pair is ruled out as the holder: `park` is an `:Update` too and installs the identical pair through `_settle_update`, and its runner is freed.
   The candidate to check first is the suspended handler frame that Future::AsyncAwait discards on the native cancel rather than resuming, which keeps its lexicals alive, `$self` there being the `WfDef::UpdateParker` instance that also reads as retained.
   The holder of the runner's one surviving reference is not yet identified.
   This is the refcount sibling of the tripwire above; one issue could carry both.

## Deviations from Plan

- Plan said: sub-step 7 notes the missing "tasks remain" tripwire as a follow-up, do not implement.
- Deviated: no deviation; the follow-up is recorded above so this summary carries it.
- Impact: FOLLOW-UP 1 above.

- Plan said: sub-step 3 routes the eviction drop "through `_classify_failure` or check the field".
- Deviated: `_settle_update` reads `$evicting` directly at the top rather than going through `_classify_failure`.
- Impact: the classifier only sees a FAILURE value, so routing through it would silence only the rejected arm and still let a handler that RETURNED on the resuming frame push an `UpdateResponse.completed`, and still let a post-accept plain die record `$current_activation_error`, on a runner being torn down.
  The direct field read also has to sit ahead of `_update_settlement` because that is where the failure converter runs, which is the escape path the new test pins.
  sdk-python's `_add_command` refuses for every arm alike while `_deleting`, so the direct check is the closer match.
  Both the `$evicting` field comment and the `_classify_failure` POD now say why the two settlement paths reach the same drop by different routes.

### Fix-loop iter 1

Validator verdict `warn`: two warns and one info, all three applied (the info at the orchestrator's direction).
Only comments changed in `Runner.pm`; everything else is test and fixture.

- Warn 1 (`code-style.comments-describe-code-as-it-is`, Runner.pm).
  The `_update_settlement` comment still credited the eviction drop of the plain-future-park arm to its own `is_cancelled` guard, which is dead reasoning now.
  Rewrote the block to say both shapes are cut off upstream and that the guard is kept for the L7 direct-call contract plus defense in depth.
  Reworded the matching sentence in `_settle_signal`'s header so it no longer says update settlement mirrors the signal path's `is_cancelled` drop.
- Warn 2 (`testing.assert-the-claimed-behavior`, `evict_pending_update_wait_condition.t`).
  The dying-converter subtest asserted "no converter ran" while only checking that the die did not escape.
  Added the `$CALLS` counter, zeroed alongside `ARMED = 1`, and asserted 0 after the eviction activation; split the old assertion text in two so each sentence matches its own check.
  MUTATION CHECK: applied both mutations at once, wrapping the `to_failure` call in `_update_settlement`'s rejected arm in `scalar eval { ... }` AND commenting out `return if $evicting`.
  Exactly the intended discrimination followed: the die-escape assertion stayed GREEN under the eval, and only the new `CALLS` assertion caught it.
  Both mutations reverted, suite re-run green.
- Info (`testing.coverage-of-both-arms`, the freed-runner subtest).
  Applied PARTIALLY, and the partial application is the interesting result.
  Widening the run to all three parked shapes turned the freed-runner assertion RED on `park_plain`.
  Bisected with a scratch probe: `cond only` and `signal only` free the runner, while `plain only`, `cond+plain` and all three do not.
  Landed the widening for the two condition-park sinks F8 actually changed, added the two ledger assertions, and documented in the test why `park_plain` is excluded, with the HEAD reproduction.
  Fixing the leak is a `Runner.pm` code change, out of scope for a fix pass and outside spec F8 ("settle SILENTLY"), so it was DEFERRED to the follow-up above.

RETRACTED in iter 2, kept here rather than silently overwritten: iter 1 wrote that "a plain-future-parked handler keeps the runner alive with NO eviction at all, so it is a reference cycle the plain-future park itself creates".
That is wrong.
An un-evicted run retains its runner in EVERY shape, including one with no handler parked at all, so that reproduction discriminates nothing.
The two neighboring iter-1 claims still hold: the three-shape run fails identically against HEAD `4aaabc7` in a detached worktree, and `evict` does cancel the awaited plain future (`is_cancelled` true after the eviction activation) while the runner still survives.

### Fix-loop iter 2

Validator verdict `warn`: one warn and one info.
The warn (`code-style.comments-describe-code-as-it-is`) accepted the scoping of the plain-future-park leak out of F8 but rejected the DIAGNOSIS the iter-1 comment and follow-up note wrote down.
The info restated the leak for the commit record and needed no edit.
This pass changed comment and notes text only: no code, no assertions.

I re-probed before rewording rather than taking the validator's account on faith, with three scratch scripts under the session scratchpad, never in the repo.

Probe 1, weak reference to the runner, four shapes, checked immediately after the eviction activation and again after dropping the dispatcher:

```
=== WITH eviction (RemoveFromCache), checked while dispatcher alive ===
  cond-update  after evict: FREED     after dispatcher dropped: FREED
  cond-signal  after evict: FREED     after dispatcher dropped: FREED
  no-handler   after evict: FREED     after dispatcher dropped: FREED
  plain-park   after evict: RETAINED  after dispatcher dropped: RETAINED
=== NO eviction, dispatcher simply dropped ===
  cond-update  after dispatcher dropped: RETAINED
  cond-signal  after dispatcher dropped: RETAINED
  no-handler   after dispatcher dropped: RETAINED
  plain-park   after dispatcher dropped: RETAINED
```

That is the validator's point, confirmed on every row.
Eviction is exactly what fails: the same `RemoveFromCache` frees the runner for both condition-park shapes and for the handler-free run, and only the plain-future park survives it.

Probe 2, a scratch fixture that weakly stashes the workflow instance and the awaited future, both `:Update` shapes, read after the eviction activation:

```
  park       runner=FREED     refcnt=-    instance=FREED     awaited=released
  park_plain runner=RETAINED  refcnt=1    instance=RETAINED  awaited=released
```

With the same stashes taken strongly instead, so the awaited future can be inspected, it reads `ready=1 cancelled=1` on `park_plain` and `ready=1 cancelled=0` on `park` (the `_ConditionFuture` override fails rather than cancels), and the runner is still FREED for `park` and RETAINED for `park_plain`, so the retention is not a probe artifact.
`$Temporalio::Workflow::Runner::CURRENT` reads undef after eviction in both shapes, so the dynamically-scoped global is not the holder.

Probe 3, the repo fixture unchanged, reading the `%CANCELS` ledger after eviction:

```
  park       resumed-with-Cancelled count after evict: 1
  park_plain resumed-with-Cancelled count after evict: 0
```

The condition-parked frame resumes and unwinds; the plain-future-parked frame never resumes, even though its awaited future reads `is_cancelled` true.
So the suspended frame is discarded rather than resumed, which fits the single surviving strong reference to the runner and the surviving workflow instance.
That also rules out the `$settle`/`on_ready` closure pair by a route the validator did not use: `park` is an `:Update` too and installs the identical pair, and its runner is freed, so the pair cannot be what distinguishes the two shapes.

No disagreement with the validator on any point; every claim in the warn reproduced.
Applied: rewrote the `park_plain` exclusion comment to the probe results above, dropping the no-eviction sentence and the "not something eviction fails to release" conclusion, keeping the HEAD `4aaabc7` reproduction and the `is_cancelled` observation.

### Fix-loop iter 3

- Warn (`code-style.comments-describe-code-as-it-is`, the `park_plain` exclusion comment).
  Applied.
  The comment claimed the discarded handler frame holds "the saved `dynamically $CURRENT` runner", which is wrong.
  Verified by grep: the only `dynamically $Temporalio::Workflow::Runner::CURRENT = $self` in the workflow path is at `Runner.pm:2157`, inside `method process_activation ($activation)` at `:2107`, a plain synchronous method rather than an `async method`.
  The other `dynamically` hits are the `$durable_suppress_depth` bump at `:3855` and the `$read_only_depth` bumps at `:3882` and `:4139`, none of them `$CURRENT`.
  Syntax::Keyword::Dynamically saves and restores a value across an `await` only for a `dynamically` made inside the suspending async sub's own frame, so a suspended `:Update` handler frame has no saved `$CURRENT` to hold at all.
  `$CURRENT` reading undef after eviction is just `process_activation` having returned and unwound its own `dynamically`.
  Dropped the clause in both the test comment and the follow-up note, replacing it with what the frame does retain (its lexicals, `$self` there being the `WfDef::UpdateParker` instance probe 2 reads as RETAINED), and stated plainly that the holder of the runner's one surviving reference is not yet identified.
- Info (`temporal.eviction-frees-run`): recorded only, no edit; it restates the follow-up above and goes into the commit body.
- Scope check: this pass touched comment lines only.
  `git diff` on the `.t` file showed no changed line without a leading `#`, and `Runner.pm` still hashed to `0d4d46143c217067f07a6c122cd3844a`.

### Fix-loop iter 4

Validator verdict `clean`.

## Key Actions

- Added `return if $evicting` at the top of `_settle_update`, ahead of `_update_settlement`, so no failure converter runs and no `UpdateResponse` is pushed during teardown.
- Rewrote the R17 comment on `_update_settlement` to say both eviction arms are cut off upstream, and to explain why the `is_cancelled` guard is kept anyway.
- Stated the sweep-order invariant once in the `evict` header and removed the `AWAIT_CLONE` aliasing overstatement, replacing it with the inherited-override explanation.
- Documented the direct-field-read choice in the `$evicting` field comment and in the `_classify_failure` POD.
- Added the `TestFailureConverter::Dying` fixture with a mutation-checked call counter.
- Added a `park_signal` `:Signal` handler and the `%CANCELS` resumption ledger to `WfDef::UpdateParker`.
- Grew `evict_pending_update_wait_condition.t` from 2 subtests to 5, including a weakened-runner assertion covering both condition-park sinks.
- Recorded two follow-ups for new GitHub issues: the missing tasks-remain tripwire and the pre-existing plain-future-park runner leak.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F8 implement) | Executed plan.md Section 6 Step F8 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: two comment warns plus a coverage info |
| Executor `mode=fix`, iter 1 | Rewrote two comment blocks, added the mutation-checked `CALLS` assertion, widened the freed-runner run to both condition parks | Applied 3, deferred the plain-park leak, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `warn`: the leak diagnosis in the new comment was wrong |
| Executor `mode=fix`, iter 2 | Re-probed with three scratch scripts, rewrote the diagnosis to the probe results | Applied 1, comment text only, suites green |
| Validator dispatch, iter 3 | Re-reviewed | verdict `warn`: the `dynamically $CURRENT` clause was wrong |
| Executor `mode=fix`, iter 3 | Verified by grep, dropped the clause from comment and notes | Applied 1, comment text only, suites green |
| Validator dispatch, iter 4 | Re-reviewed | verdict `clean` |
| Executor `mode=finalize` | Session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- The mutation check proved the new assertion discriminates rather than merely passing: under an eval-wrapped converter call the die-escape assertion stayed green and only the call counter went red, which is precisely the regression the validator described.
- Re-probing each rejected diagnosis instead of accepting the validator's account produced a sharper result than either party started with, most usefully the four-shape table that killed the reference-cycle reading outright.
- Keeping `park_plain` out of the freed-runner run, with the exclusion reasoned in the test, kept a pre-existing bug from being either hidden or dragged into F8's scope.

**What could improve:**

- The first leak diagnosis was written from a single comparison (dispatcher dropped, runner survives) that had no control arm.
  A four-shape table cost one scratch script and would have prevented two fix iterations.
- Three of the four validator round trips were spent on comment prose rather than behavior.
  Comments that assert a MECHANISM deserve the same evidence standard as an assertion; writing them last, once the probes exist, would have been cheaper.

**Course corrections:**

- The plan allowed either `_classify_failure` or a direct field read.
  Took the direct read, because the classifier only sees failures and eviction has to silence the completed arm as well.
- The coverage info was applied partially rather than wholesale, once widening the run exposed a pre-existing failure on the third shape.

## Process Improvements

- A "this leaks" claim needs a control arm before it is written into a comment: compare the suspect shape against shapes that do NOT leak, under the same teardown, and record the whole table.
- When a comment asserts why some sibling path behaves differently, name the sibling and check it.
  `park` and `park_plain` are both `:Update` handlers on the same fixture, which is what let the `$settle`/`on_ready` pair be ruled out in one line.
- After a fix pass that should be comment-only, prove it: hash the source file and grep the test diff for a changed line without a leading `#`.

## Observations

- `AWAIT_CLONE` is `shift->new` in the CPAN Future module (`Future.pm:232`), a fresh instance of the class, not an alias.
  An async sub's return future therefore INHERITS the first awaited future's cancel semantics without sharing its state, which is both why the sweep order matters and why the older aliasing wording was wrong.
- Syntax::Keyword::Dynamically only saves and restores across an `await` for a `dynamically` made inside the suspending frame itself.
  A `dynamically` in a synchronous caller like `process_activation` is unwound when that caller returns, so a suspended handler frame holds none of it.
- The two condition-park shapes and the plain-future park differ at teardown in a way nothing in the public API exposes: one resumes and unwinds, the other is discarded mid-frame.
  A ledger counting resumptions inside the workflow was the only way to see it, since the eviction completion is fixed and identical either way.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F9 keeps untyped search attributes through Schedule Action decode, which is Schedule payload and search-attribute semantics.
