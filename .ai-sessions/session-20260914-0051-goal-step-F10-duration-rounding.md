# Session Summary: Round the Shared Duration Pair Correctly (F10)

**Date**: 2026-09-14
**Duration**: single step, three dispatch modes plus a two-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F10, plan.md Section 6 Step F10 (Round the Shared Duration Pair Correctly), GitHub #14 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F10, all 8 plan sub-steps)

## The Defects

The Fable review of 674a9d5 raised warns against the shared seconds-to-Duration pair that I14 had just consolidated into `Temporalio::Core::Proto`.

A negative fractional second came out one nanosecond short.
The old split was `int(($seconds - int($seconds)) * 1e9 + 0.5)`, and `+ 0.5` rounds a NEGATIVE fraction toward zero rather than away from it, so `-1.5` encoded as `(-1, -499999999)`.

A fraction within half a nanosecond of the next second left `nanos` at one billion, which is outside the proto-legal `[-999999999, 999999999]` range: `0.9999999999` encoded as `(0, 1000000000)`.

Both defects are inherited, verbatim, from the eight old per-module copies the I14 dedup absorbed, so they had been on every seconds-to-Duration path in the SDK since those copies were written.

Neither NaN, nor Inf, nor an out-of-range magnitude was guarded at all; each encoded a mangled int64 rather than raising.

`Schedule/Spec.pm` carried a comment pointing at a scratch file that no longer exists.

## The Fix

`duration_from_seconds` now rounds the ABSOLUTE fraction and applies the sign afterwards, so `seconds` and `nanos` always share a sign.
When the rounded nanos reach one billion they carry into `seconds` and drop to zero.
`-1.5` gives `(-1, -500000000)`, `-0.25` gives `(0, -250000000)`, `0.9999999999` gives `(1, 0)`.

Input that is not a finite number throws `Temporalio::Exception::Argument`.
The guard is the full two-half house idiom from `Common/Priority.pm`: `looks_like_number` AND the `$x - $x != 0` finite check.
Either half alone is wrong, which is what the fix loop caught.

Magnitudes past protobuf's inclusive `_DURATION_SECONDS_MAX` of 315576000000 (10000 years either way) also throw.
The rounding rule and the bound are MUST-matched to `_NormalizeDuration` and `_CheckDurationValid` in protobuf 6.33.6, not derived from memory.
That bound is tighter than the 2**53 float-integrity bound the plan had in mind, so it closes the same mangled-int64 hole while staying reference-matched rather than SDK-invented.

The guard lives in this one function because the I14 dedup made it the single choke point for every seconds-to-Duration call site in the SDK, so no caller needs its own.

## Tests

`sdk/t/unit/proto.t` grew two sibling subtests, both labelled `(T-proto-6)`.

- Negative fractional seconds land on exactly `-500000000` nanos, not `-499999999`, and round-trip back to `-1.5`.
- A sub-second negative gives `(0, -250000000)` and round-trips back to `-0.25`.
- `0.9999999999` and `2.9999999996` carry into seconds and leave zero nanos.
- A numeric string `'1.5'` converts like the number it spells.
- Across seven representative inputs, nanos stay inside the proto-legal range and share a sign with seconds.
- Eight rejected inputs (NaN, +Inf, -Inf, `'abc'`, `''`, `'3abc'`, and both range bounds plus one) each die with `Temporalio::Exception::Argument`, and each asserts the DIAGNOSTIC it produces, so a guard that fires for the wrong reason fails here rather than passing on the exception class alone.
- The inclusive bounds themselves are accepted, matching protobuf's inclusive check.

Every case was RED first except the range guard, which was new behavior with no prior contract to break.

`sdk/t/unit/schedule_types.t` gained the jitter subtest the spec called for: a 30-second jitter and a fractional 1.5-second jitter survive a real encode-decode wire crossing, and both a zero jitter and an omitted one decode back to `undef`, since proto3 drops an all-default sub-message and cannot tell the two apart.

## The Spec.pm Comment

The dangling pointer was retargeted to the I14 session summary.

Three lines were added explaining why `_timestamp`'s naive `+ 0.5` split is safe where it sits, and the first version of them gave the WRONG reason.
Positivity does not exclude the carry: `_timestamp(0.9999999999)` still yields nanos of one billion, and `_timestamp(-1.5)` still yields negative nanos that Timestamp forbids.
What actually rules the carry out is the SPACING of doubles at real epoch magnitudes.
From 2**30 seconds (2004-01-10) on, adjacent doubles are about 238 nanoseconds apart, so no representable fraction can land within the half nanosecond of the next second that the carry needs.
The nearest double below epoch 1773000000 splits to `(1772999999, 999999762)`.
The negative case is out of reach for a different reason: pre-epoch schedules are unsupported, and `start_at`/`end_at` are never validated non-negative, so a negative one would build an illegal Timestamp either way.

Both belong to the tracked Timestamp sibling follow-up, not to F10.

## Deviations from Plan

- Plan said: sub-step 1, "Extend sdk/t/unit/proto.t T-proto-6" with the rounding cases.
- Deviated: added two sibling subtests, both labelled `(T-proto-6)`, rather than growing the existing one.
  The original subtest already ran 11 assertions; the rounding and the guard cases are separate concerns and read better apart.
- Impact: none on coverage.
  `grep 'T-proto-6'` still finds every assertion for the ID.

- Plan said: sub-step 1, NaN and Inf "either die with Temporalio::Exception::Argument or are documented as caller-validated (choose, document)".
- Deviated: chose the throw, and widened it to a range check against protobuf's inclusive `_DURATION_SECONDS_MAX` (315576000000) instead of the 2**53 bound the dispatch mentioned.
- Impact: strictly tighter than 2**53, so it still closes the mangled-int64 hole, and it is MUST-match with `_CheckDurationValid` rather than an SDK-invented bound.
  No call site in the SDK sends anything near 10000 years, and the full suite (960 tests, live integration included) is green, so nothing regressed.
  Any caller that wanted Inf as an "infinite timeout" sentinel now gets an Argument error, which is the intended contract.

- Plan said: sub-step 6, "Fix the Spec.pm ~104 comment to point at the I14 session summary or drop the pointer."
- Deviated: retargeted the pointer AND added three lines saying why `_timestamp`'s naive `+ 0.5` split is safe where it sits.
- Impact: the next reader who diffs the two splits gets the answer in place instead of filing a duplicate of F10 against the Timestamp helper.

### Fix-loop iter 1

Validator verdict `warn`: one warn plus one info, both applied.

- Warn (`sdk.argument-validation`, `Proto.pm:125`).
  The F10 guard cited the `Common/Priority.pm` house idiom but kept only its FINITE half.
  Confirmed by probe: `'abc'` and `''` split to `(0, 0)` and `'3abc'` to `(3, 0)`, each with nothing louder than an "isn't numeric" warning.
  Fixed by adding `use Scalar::Util ();` and extending the first throw to `!Scalar::Util::looks_like_number($seconds) || $seconds - $seconds != 0`.
  Three string cases were added to the `%bad` table in `proto.t` (RED first: six failing assertions, then green), and the POD claim that input "is otherwise taken as-is" was reworded.
  Probe before editing: `looks_like_number` accepts every shape the nine call sites can pass (integers, floats, `'1.5'`, `'1e3'`, `'+3'`, a padded `' 1'`, `'0 but true'`, and numification-overloaded objects) and rejects `'abc'`, `''`, `'3abc'`, `'1.5.2'`.
  It returns TRUE for the strings `'Inf'` and `'NaN'`, so the finite check has to stay ALONGSIDE it, not replace it.
- Info (`comment.accuracy`, `Spec.pm:108`).
  The new `_timestamp` note gave the wrong reason.
  Reworded to the double-spacing reason above, verified by probe.

Impact of the pass: no behavior change for any in-tree caller.
The guard only rejects input that previously encoded a silently wrong Duration.

### Fix-loop iter 2

Validator verdict `clean`, with two info findings applied during finalize:

- `proto.t`'s `%bad` loop asserted only the exception class, so a range rejection could have swallowed a NaN unnoticed.
  Each row now carries the regex its diagnostic must match, and the loop asserts it.
- `Proto.pm` cited `well_known_types.py:451-482`, which does not match the installed 6.33.6 (`_NormalizeDuration` sits at 462, `_CheckDurationValid` at 485).
  Both citations in the file now name the function or constant and the point release, with no line numbers to go stale.

## Key Actions

- Rewrote `duration_from_seconds` to round the absolute fraction, apply the sign afterwards, and carry into seconds when the rounded nanos reach one billion.
- Added the two-half finite guard and the inclusive `_DURATION_SECONDS_MAX` range check, both raising `Temporalio::Exception::Argument`.
- MUST-matched the rounding rule and the bound against `_NormalizeDuration` and `_CheckDurationValid` in protobuf 6.33.6.
- Added two `(T-proto-6)` subtests to `proto.t` covering negatives, the carry, string input, six non-finite or non-numeric rejections, and both range bounds, each asserting its own diagnostic.
- Added the jitter wire round trip and zero-to-undef decode fold to `schedule_types.t`.
- Retargeted the `Schedule/Spec.pm` pointer to the I14 session summary and documented why `_timestamp`'s naive split is safe at real epoch magnitudes.
- Documented the rounding, the carry, and the throw contract in `Core::Proto`'s POD.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F10 implement) | Executed plan.md Section 6 Step F10 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: one warn plus one info |
| Executor `mode=fix`, iter 1 | Added the `looks_like_number` half, corrected the `_timestamp` reason | Applied 2, three string cases added, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean`, two info findings |
| Executor `mode=finalize` | Applied both info findings, session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Probing `looks_like_number` against every shape the nine call sites can pass, BEFORE editing, is what surfaced that it accepts `'Inf'` and `'NaN'`, which is the reason both halves of the guard have to stay.
- Reading the installed protobuf rather than quoting it from memory produced a tighter, reference-matched bound than the 2**53 one the plan assumed.
- Asserting the diagnostic per row, not just the exception class, makes the two guards distinguishable in the test output.

**What could improve:**

- The implement pass cited the `Common/Priority.pm` idiom in a comment while implementing only half of it.
  Citing an in-tree idiom should mean re-reading it, not recalling it.
- The `_timestamp` safety note was written from a plausible-sounding reason (positivity) rather than from a probe.
  The probe took one command and disproved it.
- The `well_known_types.py` line anchors were written from a remembered 6.x layout rather than the installed tree, which is the second stale-anchor finding in two steps.

**Course corrections:**

- The plan offered "die or document as caller-validated" for NaN and Inf; the throw was chosen, and widened to a full range check.
- The guard's bound moved from the dispatch's 2**53 suggestion to protobuf's `_DURATION_SECONDS_MAX`.

## Process Improvements

- Cite reference-SDK and library source by FUNCTION or CONSTANT NAME plus the exact point release, never by line number.
  Two consecutive steps have now produced a stale line anchor.
- When a comment claims a piece of code is safe, prove the claim with a probe before writing it.
  A wrong safety comment is worse than none, because the next reader stops looking.
- When copying an in-tree idiom, open it.
  Half an idiom carrying the full idiom's citation reads as verified when it is not.

## Observations

- The I14 dedup is what made this step small: one function to fix instead of eight, and one place to put the guard so that no call site needs its own.
  It is also what made the defect universal in the first place, since all eight copies shared the same wrong rounding.
- The house "finite number" guard is genuinely two halves doing different jobs: `looks_like_number` catches what Perl would numify silently, and `$x - $x != 0` catches what `looks_like_number` accepts.
- The `Timestamp` seconds/nanos pairs in the Schedule modules carry the same naive split and are NOT fixed here.
  They remain the tracked sibling follow-up; the Spec.pm comment now records exactly why they happen to be safe in place.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F11 proves `fetch_history` pages, which is Temporal history pagination and next-page-token semantics.
