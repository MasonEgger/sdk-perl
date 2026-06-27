# Session Summary: B9 re-scoped — #1 is a samples-perl import bug, not an SDK signal-fd bug

**Date**: 2026-06-26
**Duration**: ~10 minutes
**Conversation Turns**: 1 (single autonomous dispatch)
**Estimated Cost**: ~$1.5 (Opus, mostly file reads + one full test run)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: doc-only plan correction; B9 re-scoped to "no SDK bug"; suite stays green at 538; push to origin/v1
- **Mode**: step
- **Outcome**: converged (doc-only correction committed and pushed)
- **Turn count**: 1
- **Subagent dispatches**: 1 (this one)
- **Steps completed**: B9 re-scope across plan.md, todo.md, ROOT-CAUSE-MAP.md (B9.1/B9.2 marked done; B9.3/B9.4/B9.5 marked N/A)

## Key Actions

- Verified the B9 investigation premise directly against `samples-perl/sync-activity`:
  `lib/SyncActivity/Activities.pm` does `use SyncActivity::Compute qw(count_primes)`
  at file scope (package `main`), before the `class SyncActivity::Activities` block,
  so the unqualified `count_primes(...)` inside the class resolves to an undefined
  `SyncActivity::Activities::count_primes`. Confirmed the import bug, not an SDK fd bug.
- Re-scoped Step B9 in plan.md: stated plainly there is NO SDK signal-fd bug (fork-pool /
  signal-fd path verified healthy), that #1 is a samples-perl import bug, and that the
  "signal fd write failed (Bad file descriptor)" line is a benign teardown-race artifact.
  Recorded the four verified disproof points (in-process repro fails identically with no
  fork; parent signal fd stays open per dup probe; a correct sync `:Defn(...,'sync=1')`
  activity returns 25 live through the fork pool; eventfd is already EFD_CLOEXEC).
- Moved the #1 fix into the B8 samples-reconciliation list (qualify the call to
  `SyncActivity::Compute::count_primes(...)` or import into the activity's own package;
  then drop the `TEMPORAL_SYNC_ACTIVITY_LIVE` gate and the stale "wedges the worker loop"
  comment in `sync-activity/t/02-smoke.t`). Noted the harmless optional SDK log-hygiene
  hardening as a nice-to-have, not a bug.
- todo.md: marked B9.1/B9.2 `[x]` (diagnosis corrected: not an SDK bug); marked
  B9.3/B9.4/B9.5 `[x]` N/A with a pointer to B8 reconciliation #1, so the loop stops
  trying to make an SDK fix for a non-bug. Updated the B8 reconciliation note from FOUR
  residual SDK bugs down to TWO real SDK fix steps (B10 #4, B11 #10) plus the samples fix.
- ROOT-CAUSE-MAP.md: corrected the residual-findings #1 row (samples-perl import bug,
  benign signal-fd message), corrected the #11 row to re-verify INDEPENDENTLY (shares no
  fd path), and superseded the earlier "B9 fixes a production signal-fd corruption" note.
- Ran the full Perl suite: 538 tests, Result: PASS (doc-only, suite unchanged).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Doc-only B9 re-scope across 3 files + session summary, one green-safe commit, push to origin/v1 | Verified samples evidence, edited plan.md/todo.md/ROOT-CAUSE-MAP.md, ran suite, wrote summary, committed, pushed | 538 pass; one commit; pushed |

## Efficiency Insights

**What went well:**
- Verified the import-bug premise against the actual samples-perl source before writing
  the correction, rather than trusting the prompt narrative blindly.
- Single full-suite run confirmed doc-only safety; no source/test files touched.

**What could improve:**
- Nothing notable for a doc-only correction.

**Course corrections:**
- None.

## Process Improvements

- When a multi-investigator bug narrative gets inverted, scrub every cross-reference: the
  old framing leaked into the B8 reconciliation prose, the Implementation Guidelines line,
  and two separate "correction" notes in ROOT-CAUSE-MAP.md, not just the B9 step itself.

## Observations

- The "signal fd N write failed (Bad file descriptor)" line cost three prior investigators
  real time. It is teardown noise printed after the await already failed. A benign log line
  that looks like a smoking gun is an expensive trap.
- Perl `use Foo qw(bar)` imports into the package in effect at the `use` line, which is the
  file's default `package main`, NOT a later `class Foo::Bar { ... }` block. Unqualified
  calls inside the class silently miss the import.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — the next real SDK fix is B10.1 (wait_condition-with-timeout
  timer cancel/re-arm wedge in Runner.pm), a durable-timer determinism bug.
