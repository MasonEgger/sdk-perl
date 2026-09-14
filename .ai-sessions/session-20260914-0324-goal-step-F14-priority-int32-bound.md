# Session Summary: Bound Priority to What the Wire Carries (F14)

**Date**: 2026-09-14
**Duration**: single step, three dispatch modes plus a one-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F14, plan.md Section 6 Step F14 (Bound Priority to What the Wire Carries), GitHub #10 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (1), finalize (1)
- **Steps completed**: 1 of 1 (F14, all 8 plan sub-steps)

## The Gap

The Fable review of d855b84, which added the `priority_key` construction guard, raised three warns against what that commit left behind.

The guard had a lower bound and no upper one.
`priority_key` encodes into an int32 proto field (`share/proto/temporal/api/common/v1/message.proto:318`), so any value above 2147483647 passed construction, travelled through the object, and died much later inside the codec as `Protobuf::Exception::Codec::OutOfRange`.
That is the wrong class at the wrong place: a caller who passed a bad key got a serialization error from an encode they did not write instead of an argument error at the line where they supplied the value.

An object with overloaded numification passed every clause.
`Scalar::Util::looks_like_number` follows the overload, `int()` follows it, and so do both comparisons, so a blessed reference whose `0+` returns 7 constructed cleanly and only failed at encode with a proto type mismatch.
The guard tested what the value looked like numerically and never tested what it was.

The guard comment understated what the guard accepts.
It said "a positive integer (>= 1)", which reads like Python's `isinstance(int)` and is not what the Perl code does: `looks_like_number` tolerates whitespace padding, exponent notation, an explicit sign, and whole floats, all of which pass.

## The Fix

The guard now tests `ref` first, before any numeric clause, and only then `looks_like_number`, equality with its own `int()`, the finiteness check, `>= 1`, and `<= 2147483647`.
Clause order is the whole point of the `ref` test: it has to run before the numeric clauses, because once numification is in play an overloaded object satisfies all of them.

The thrown class is unchanged, `Temporalio::Exception::Argument`, and the message grew to name the ceiling: `priority_key must be a positive integer no greater than 2147483647`.
The old wording survives as a literal substring, so spec.md I10's phrasing and every existing `qr/priority_key/` assertion still hold.

The same `ref` clause was added to the sibling `fairness_weight` guard, which had the identical hole in the identical shape.
No upper bound belongs there because that proto field is a double.

The comment was rewritten into an explicit ACCEPTED list and REJECTED list, so the divergence from Python is stated rather than implied.
The POD on both parameters now states the int32 range, the reference rejection, and the looser-than-Python accept set.

## The Tests

`sdk/t/unit/priority_fairness.t` extends the existing rejection matrix with `2**31` and `3e9`, both RED before the upper-bound clause landed.

A new subtest constructs `Temporalio::Test::OverloadedNumber`, a package whose `0+` returns 7 and whose `""` returns `seven`, and asserts that both `priority_key` and `fairness_weight` reject it with `Temporalio::Exception::Argument`.
Without the `ref` clause that object constructs, which is exactly the false pass the review predicted.

A round-trip subtest encodes and decodes through the real `temporal.api.common.v1.Priority` message for four accepted forms: `2147483647` (the ceiling itself, a legal key), `"3"`, `" 1"`, and `"1e0"`.
Pinning the ceiling as accepted is what keeps a future off-by-one from quietly narrowing the range.

The comment's accept and reject lists were probed at the REPL rather than asserted blind before being written down.
Two results were worth keeping: `"0 but true"` numifies to 0 and so falls to the `< 1` clause rather than the `looks_like_number` clause, and a dualvar fails `looks_like_number` on its string half.

## Python Parity

`temporalio/common.py:1222-1228` allows `None`, rejects a non-int, and rejects anything below 1, all at construction.
It has no int32 ceiling clause, because Python's protobuf raises inside `_to_proto` when the value overflows.
Perl's upper bound is therefore an addition, not a divergence in semantics: it moves the same rejection earlier, to construction, where the caller can act on it.

The real divergence is on the accept side and is now documented: Python's `isinstance(int)` refuses `"3"` and `3.0`, while the Perl guard takes both.

## Deviations from Plan

- Plan said: sub-step 3 adds `ref` and the int32 upper bound to the priority_key guard only; sub-step 4 says "RED: none further".
- Deviated: also added `ref $fairness_weight ||` to the sibling fairness_weight guard, plus one extra RED assertion in the new overloaded-object subtest covering it.
  The sibling guard had the identical hole the plan diagnoses for priority_key: an object with overloaded `0+` satisfies looks_like_number, constructs cleanly, and dies later at encode with a proto type mismatch rather than Temporalio::Exception::Argument.
  The dispatch explicitly authorized closing it if it could be done in the same shape without changing fairness_weight semantics, which it can: no non-reference input changes behavior, and there is no upper bound to add because the proto field is a double.
- Impact: the diff is one clause and five test assertions wider than spec F14 strictly requires.
  The validator raised this as an info, and spec.md F14 gained one sentence at finalize so the spec matches the code.

- Plan said: nothing about the error message text.
- Deviated: widened the priority_key message from `priority_key must be a positive integer` to `priority_key must be a positive integer no greater than 2147483647`, because 2**31 IS a positive integer and the old text would have been actively misleading for the new rejection case.
  The old wording survives as a literal substring, so spec.md I10's phrasing and the test's `qr/priority_key/` both still hold.
  Grep confirmed the string is asserted nowhere else.
- Impact: none on tests.
  Python's messages stay split across TypeError and ValueError; Perl already collapsed both into one Argument before this step.

- Plan said: nothing about stale line anchors.
- Deviated: replaced the `_from_proto (:82-90, zero-to-undef map at :84)` anchor in the guard comment with a method-name anchor.
  The numbers were already stale before this step and these edits shifted them further; house rules want method names, not line numbers.
- Impact: comment-only.

### Validation, iter 1

Validator verdict `clean`, with two info findings and no block or warn.

The first info observed that the fairness_weight guard had been extended beyond spec F14's text, leaving the spec narrower than the code.
Applied at finalize: spec.md's F14 Required paragraph gained one sentence stating that the sibling guard also rejects references.

The second info recorded a test-suite flake, described below.

## The schedule.t Flake

The full `prove -lj4 t` gate failed once during the implement dispatch on `t/integration/schedule.t` subtest 3 (trigger twice, expect `num_actions == 2`).
It passed standalone and on a clean full re-run, and again on both finalize runs.
`lessons.md:195` already documents the mode: two schedule triggers fired back-to-back can collapse into one action on the dev server.
`schedule.t` has zero Priority references, so nothing in this diff is reachable from it.
Recorded as a known live-server flake rather than a regression, and no test was loosened.

## Key Actions

- Added a `ref` clause as the first test in the `priority_key` guard, ahead of every numeric clause.
- Added the int32 upper bound (`> 2_147_483_647`) and widened the exception message to name the ceiling while keeping the old text as a substring.
- Added the same `ref` clause to the sibling `fairness_weight` guard.
- Extended the rejection matrix with `2**31` and `3e9`, RED before the upper-bound clause.
- Added an overloaded-numification package to the test file and asserted rejection on both parameters.
- Added an encode and decode round trip pinning `2147483647`, `"3"`, `" 1"`, and `"1e0"` as accepted.
- Rewrote the guard comment into explicit ACCEPTED and REJECTED lists, probed rather than assumed.
- Updated the Priority POD on both `priority_key` and `fairness_weight`.
- Appended one sentence to spec.md F14 at finalize, per the validator's info.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F14 implement) | Executed plan.md Section 6 Step F14 sub-steps 1-8 | Dirty tree, both suites green after one re-run, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `clean`, two infos |
| Executor `mode=finalize` | Applied the spec info, session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Probing the accept and reject lists at the REPL before writing the comment caught two cases that intuition had backwards, `"0 but true"` and the dualvar.
- Asserting the ceiling value itself as accepted, not only the value above it, is what pins the boundary in both directions.
- Diagnosing the overload hole on `priority_key` made the identical hole on `fairness_weight` visible immediately, since both guards were written from the same template.

**What could improve:**

- The first full-suite run was treated as a possible regression for longer than the evidence justified; `schedule.t` has no Priority reference, and grepping that first would have reached the flake verdict sooner.
- Widening the fairness_weight guard without a matching spec sentence left the spec behind the code for one validation round.
  Extending both in the same pass would have avoided the info.

**Course corrections:**

- Kept the old exception wording as a substring of the new message, rather than replacing it, so existing assertions and the spec's I10 phrasing survive.
- Replaced the stale line-number anchor in the guard comment with a method name while editing nearby.

## Process Improvements

- When a guard is extended, check every sibling guard written from the same template in the same file before finishing the step.
- When a step widens a guard past what the spec sentence says, edit the spec in the same commit; the validator will otherwise flag the drift.
- A test-suite failure in a file with no reference to the code under change is a flake until proven otherwise; grep first, then re-run.

## Observations

- This guard had accumulated its clauses one review at a time, and each addition tested the value as a number.
  The `ref` clause is the first one that tests what the value is, which is why it has to run first.
- The int32 ceiling is a case where Perl can give a better error than Python does, because Python defers the range check to protobuf and Perl's dynamic codec would accept the value and fail later.
- The accept list is genuinely looser than Python's and now says so out loud in three places: the guard comment, the POD, and the round-trip test.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F15 pins the `count_workflows` aggregation group shape, which is a Temporal query-response question.
