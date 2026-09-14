# Session Summary: Settle an Evicted Async :Update Parked on wait_condition Without Croaking (I1)

**Date**: 2026-09-13
**Duration**: single dispatch (finalize-only; implement/validate ran in prior dispatches)
**Conversation Turns**: n/a (autonomous `/bpe:goal` dispatch)
**Estimated Cost**: n/a
**Model**: claude-sonnet-5

## Goal Context

- **Condition**: land I1 (GitHub issue #1): evicting a run with a pending async `:Update` handler parked on `wait_condition` must not croak; the eviction completion must still be sent.
- **Mode**: step
- **Outcome**: converged (this step)
- **Turn count**: n/a
- **Subagent dispatches**: implement, validate (iter 1, clean + em-dash warn in test comments; iter 2, fix pass, clean), finalize (this dispatch)
- **Steps completed**: 1 (Section 1, Step I1)

## Key Actions

- Diagnosed the mechanism: an async `:Update` handler parked on `wait_condition` has its Future::AsyncAwait method future built as an AWAIT_CLONE of the underlying `_ConditionFuture` (the first future the handler body awaits). `evict()`'s old sweep order hit `%in_progress_handlers` before `@conditions`, so the handler pass cancelled the clone first (the `_ConditionFuture` cancel override maps to `->fail(Cancelled)`, settle #1), then the later conditions pass failed the REAL underlying condition, resuming the suspended handler frame; Future::AsyncAwait then tried to `->fail` the method future a second time and croaked "is already failed and cannot be ->fail'ed" before the eviction (RemoveFromCache) completion was ever sent.
- Fixed in `evict()`'s `@pending_futures` snapshot, `sdk/lib/Temporalio/Workflow/Runner.pm` around :2201-2232: reordered the sweep to hit `@conditions` BEFORE `%in_progress_handlers`. Failing the real `_ConditionFuture` first resumes the handler frame and lets Future::AsyncAwait settle the clone as part of that same cancel; the later handler-future pass then finds the clone already `->is_ready` and the loop's existing `unless $future->is_ready` guard skips it. Exactly one settle reaches the method future. No new helper was extracted (plan sub-step 6): the reorder reuses the same sweep-then-guard discrimination the R8-R10 fix already established for the main run future's cancel fallback.
- Extended the pre-existing `sdk/t/lib/WfDef/UpdateParker.pm` fixture in place (one attributed class, per Directive 6) rather than adding a new file: added a `park_plain :Update('park_plain')` handler that parks on a plain `Temporalio::Workflow::Future` (the R17/`PlainFutureUpdater` shape, natively cancellable). A run holding both `park` (wait_condition) and `park_plain` (native cancel) in flight at once exercises the mixed-parking eviction case in a single class without touching what `repro_cancel_mid_update.t` already depends on.
- Added `sdk/t/replay/evict_pending_update_wait_condition.t`: two subtests. The first reproduces the single wait_condition-parked update croak and confirms it is gone (eviction completion sent, no commands, runner dropped). The second (plan sub-step 4) covers the mixed case: both a plain-future-parked and a wait_condition-parked update in flight on the same run, evicted together, exactly one eviction completion.
- Corrected the `evict()` doc comment to state the new contract: sweep `@conditions` before `%in_progress_handlers` and why.
- Full suite green: `prove -lj4 t` (201 files, 868 tests) and `prove -lj4 xt` (8 files, 463 tests).
- Validator ran twice: iter 1 cleared the code on the merits and raised one warn (an em-dash in test comments); the fix pass resolved it comment-only, no logic touched. Iter 2 clean.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator finalize dispatch for Step I1 | Ran both test suites, wrote this summary, appended a lesson, generated commit message, committed and pushed | Single clean commit, pushed |

## Efficiency Insights

**What went well:**
- The mechanism was already diagnosed and recorded as an unfixed candidate finding in `.ai-sessions/lessons.md` (2026-07-08, R8-R10 entry) and in `session-20260708-1748`, so the implement pass had a known-good repro path and root cause going in rather than starting from scratch.
- The R8-R10 sweep-then-guard pattern transferred directly: no new abstraction was needed, just a reorder of an existing list-building sweep.

**What could improve:**
- Nothing notable for this finalize dispatch; it is a pure commit-transaction step on already-validated work.

**Course corrections:**
- None.

## Process Improvements

- None new.

## Observations

- The mixed-parking test (plan sub-step 4) is the useful regression guard here: a fix that only reorders two sweep buckets could plausibly break the OTHER bucket's discrimination silently; the mixed-case subtest pins both arms settling exactly once in the same eviction.

## Suggested Skills for Next Session

- None specific; the remaining todo.md items (I5 onward) are again Worker/Runner internals, same skill surface already in use.

## Deviations from Plan

- None recorded in `.ai-sessions/implementation-notes.md` for this step.
