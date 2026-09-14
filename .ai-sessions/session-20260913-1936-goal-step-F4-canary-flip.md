# Session Summary: Make the Two-Classes Canary Able to Flip and Correct Its Record (F4)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a two-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor dispatches), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F4, plan.md Section 6 Step F4 (Make the Two-Classes Canary Able to Flip and Its Claims True), GitHub #18 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F4, all 8 plan sub-steps)

## The Defect

The Fable review of b510bd9 (the I18 canary) found two separate problems in one commit.

First, the canary could not flip.
`T2->todo(...)` wrapped the entire `T2->subtest`, so the top-level TAP line was `ok 5 # TODO` today and would stay `ok 5 # TODO` after an upstream fix.
A harness that reports the same line in both states is not an alarm, it is decoration.

Second, the claims were false.
The I18 commit body, its upstream-report draft, and a fresh `lessons.md` entry all said the two-classes shape reproduces without Future::AsyncAwait under plain `perl -c`.
It does not.
The probe behind that claim loaded `Temporalio::Workflow`, whose line 8 is `use Future::AsyncAwait;`, so every run labelled "no F::AA" had F::AA loaded transitively.
The same entry also advised that a canary needs a real fixture file because the `eval q{...}` form does not reproduce.
That is backwards as well: the eval-string form reproduces with the same message and the same line offset.

## The Fix

- `T2->todo` now wraps only the two inner assertions that state the desired end state (`$ok` is true, `$err` is empty), and the `eval` plus its `$@` capture moved above the todo block so both the todo'd assertions and the guard below read the same captured `$err`.
- A non-TODO `T2->like($err, qr/Subroutine attributes must come before the signature/)` sits outside the amnesty.
  It is the flip alarm and the wrong-reason guard in one: on an upstream fix `$err` goes empty and the `like` goes red, failing the subtest and the file; on a fixture rot (a renamed `:Run` handler, a `TwoA::*` package collision, a load error) it also goes red instead of letting an unrelated death stand in for #18.
- `require Temporalio::Workflow` was dropped from the canary; only `Future::AsyncAwait` and `Temporalio::Workflow::Definition` are loaded now, so the test states its own dependency honestly.
- The header comment now says loading Future::AsyncAwait is part of the reproduction rather than a convenience, cites the corrected 2026-07-10 lessons entry by its opening text, and spells out the flip signal: the inner assertions start reporting "TODO passed" AND the `like` goes red at the same moment.
- Today the file reports 5 plain `ok` lines with two inner `not ok ... # TODO` failures under amnesty, and `grep -c "TODO passed"` over the harness output returns 0 suite-wide.
  Before this step the harness printed `TODO passed: 5`.
- A flip was simulated in the scratchpad by forcing `$ok = 1` and `$err = ''`: the `like` goes red, the subtest fails, the file exits 1, and prove prints `Result: FAIL`.

## Corrected Upstream-Report Draft

The I18 commit body and its upstream-report draft are immutable under the no-amend rule.
This is the corrected, self-contained replacement.

**Title**: `feature 'class'` + attributes: a signatured method in one class poisons the next `class :isa(...)` declaration when Future::AsyncAwait is loaded

**Where it belongs**: the Future::AsyncAwait tracker.
Future::AsyncAwait is required to reproduce this shape; without it the file compiles clean.
Do NOT conflate it with the core-only variant already known here (a file-scope signatured named `sub` compiled before a `class` block poisoning a later attribute-bearing declaration with NO F::AA loaded); that variant reproduces without F::AA and is a separate perl5 report.

**Versions**: perl 5.38.2 (`x86_64-linux-gnu-thread-multi`), Future::AsyncAwait 0.71.

**Reproduction**, no SDK, no `Attribute::Handlers`, no other dependency:

```perl
use v5.38;
use feature 'class';
no warnings 'experimental::class';
class ProbeBase { sub MODIFY_CODE_ATTRIBUTES { () } }
class ProbeOne :isa(ProbeBase) { method run :Run('X') ($i) { return $i } }
class ProbeTwo :isa(ProbeBase) { method run :Run('Y') ($i) { return $i } }
```

```
$ perl -c two_classes.pl
two_classes.pl syntax OK

$ perl -MFuture::AsyncAwait -c two_classes.pl
Subroutine attributes must come before the signature at two_classes.pl line 6.
```

`MODIFY_CODE_ATTRIBUTES` returning the empty list is what lets `:Run` be an arbitrary unregistered attribute with no `Attribute::Handlers` dependency.

**Expected**: both invocations print `syntax OK`.
Merely loading Future::AsyncAwait, without using `async` or `await` anywhere in the file, should not change how perl parses a `class` block.

**Actual**: with Future::AsyncAwait loaded, the second `class ... :isa(...)` declaration dies at compile time.
The diagnostic points at the second class and names a construct (`method run :Run('Y') ($i)`) whose attribute already does come before the signature, so it misdirects.

**Narrowing** (all under `perl -MFuture::AsyncAwait -c`):

1. Make both methods signature-less (`method run :Run('X') { ... }`): compiles.
   A signature on the first class's method is necessary.
2. Drop the attribute from the second class's method, keeping its signature: still dies, still at the second class's line.
   The second class's own method attribute is not the trigger.
3. Insert a file-scope signature-less named sub (`sub reset_ {}`) between the two classes: compiles.
   This is the known reset for the core-only variant of this family and it works here too.

So the trigger is the first class's signatured, attributed method leaving parser state that the NEXT `class ... :isa(...)` line trips over, and Future::AsyncAwait's presence is what arms it.

**Also reproduces** inside `eval q{...}`, with the same message and the same line offset.

**Reproduction caveat for anyone re-running this**: do not name a probe class after a core module.
Future::AsyncAwait loads `B`, so any variant expected to print `syntax OK` (the negative controls) instead dies with `Cannot create class B as it already has a non-empty @ISA`.
The masking is order-dependent.
When `B` is the SECOND class the main reproduction still survives: with the two classes named `A` and `B`, `perl -MFuture::AsyncAwait -c` reports the parse death at the second class as usual.
With `B` FIRST the `@ISA` error masks the reproduction as well, since class creation dies before the parser ever reaches the second declaration.
Name probe classes anything but `B`.

**Downstream impact**: the Temporal Perl SDK carries a one-attributed-class-per-file rule because of this.
Workflow definition classes use exactly this shape (`class X :isa(Temporalio::Workflow::Definition)` with `method run :Run('X') ($i)`), and the SDK loads Future::AsyncAwait, so two workflow classes cannot share a file.
Tracked as GitHub issue #18 on the SDK side, with a canary at `sdk/t/unit/attribute_handlers.t` that fails loudly when the behavior changes.

## The Probe Record

Versions: perl 5.38.2 `x86_64-linux-gnu-thread-multi`, Future::AsyncAwait 0.71.
Probe files were written under the scratchpad, never in the repo.

Main reproduction, the five-line no-SDK file above:

```
perl -c                        : two_classes.pl syntax OK
perl -MFuture::AsyncAwait -c   : Subroutine attributes must come before the signature at two_classes.pl line 6.
```

Line 6 is the second class.

Negative control 1, signature-less methods (`method run :Run('X') { return $_[1] }` in both classes):

```
perl -c                        : ctl1_no_signature.pl syntax OK
perl -MFuture::AsyncAwait -c   : ctl1_no_signature.pl syntax OK
```

Negative control 2, second class carries NO method attribute (`method run ($i) { return $i }`):

```
perl -c                        : ctl2_second_unattributed.pl syntax OK
perl -MFuture::AsyncAwait -c   : Subroutine attributes must come before the signature at ctl2_second_unattributed.pl line 6.
```

Still dies, and still at the second class's line.
The trigger is therefore the `:isa` on the second `class` line following a signatured method in the first, not the second class's own method attribute.

Negative control 3, file-scope signature-less named sub between the classes (`sub reset_ {}`):

```
perl -c                        : ctl3_reset_sub.pl syntax OK
perl -MFuture::AsyncAwait -c   : ctl3_reset_sub.pl syntax OK
```

This is the same reset that `Runtime/MetricMeter.pm` already uses as a firewall.

Eval-string form, `eval q{ ... }` wrapping the same three classes:

```
no F::AA : eval COMPILED
F::AA    : eval DIED: Subroutine attributes must come before the signature at (eval 6) line 6.
```

The eval-string form DOES reproduce.
The I18 lesson's advice that a canary needs a real fixture file rather than an `eval q{...}` string was wrong.

Provenance of the false "no F::AA required" claim: the I18 probe loaded `Temporalio::Workflow`, whose line 8 is `use Future::AsyncAwait;`.
Every "plain `perl -c`" run in that probe had F::AA loaded transitively.

Class-name caveat: naming a probe class `B` collides with the core `B` module that Future::AsyncAwait loads (`@B::ISA = (Exporter)`).
The collision masks the negative controls first: a variant that should print `syntax OK` dies with `Cannot create class B as it already has a non-empty @ISA` instead.
It is order-dependent from there.
With `B` as the SECOND class a reproducing file named `A`/`B` still shows the parse death at the second class.
With `B` FIRST the `@ISA` error masks the reproduction as well, so probe classes must never be named `B`.

## The Corrected Lessons Entry

The contradicting I18 sibling in `## Recent` was deleted outright.
The durable statement now lives as an F4 correction addendum folded onto the 2026-07-10 parser-state entry under `## Workflow`, which is the entry the canary comment cites.
It records: two attributed `:isa` classes back to back in one unit suffice with no intervening signatured sub, but only under Future::AsyncAwait; the minimal SDK-free proof; the transitive-load provenance of the false reading; the three controls; that the `eval q{...}` form does reproduce; and the `B`-collision caveat.

## The .gitignore Addition

`.ai-sessions/implementation-notes.md` is now gitignored.
The step-executor protocol treats that file as gitignored scratch, and it was not, so a `git add -A` anywhere in the loop would have swept it into a commit.

## Deviations from Plan

- Plan said: sub-step 2 writes the no-SDK probe as `class Base { ... }` plus two `:isa(Base)` classes named in the review as a generic two-class shape.
- Deviated: the first pass used class names `A` and `B`.
  `B` collides with the CORE `B` module, which Future::AsyncAwait pulls in (`@B::ISA = (Exporter)`), so two of the three negative controls failed with `Cannot create class B as it already has a non-empty @ISA` instead of reporting the parser-state result.
  Renamed to `ProbeBase` / `ProbeOne` / `ProbeTwo` and re-ran; all four files then matched the review's predictions.
- Impact: none on the finding.
  It does add a caveat the upstream report must carry: a reproduction file must not name a class after a core module, or the class-creation error masks the parse error.

- Plan said: sub-step 3 rewrites "lessons.md line 5 (the I18 entry)".
- Deviated: the file had rotated; the I18 entry was at line 12, and the 2026-07-10 parser-state entry it contradicts was at line 97.
  Located both by opening text, removed the false sibling from `## Recent`, and folded an F4 correction addendum onto the 2026-07-10 entry in `## Workflow`.
- Impact: `## Recent` now holds 9 entries (cap is 10 maximum, not a floor).
  The durable statement of the corrected finding lives on the 2026-07-10 entry, which is what the canary comment cites.

- Plan said: nothing about `.gitignore`.
- Deviated: added `.ai-sessions/implementation-notes.md` to `.gitignore`.
  The step-executor protocol treats this file as gitignored, and it was not.
- Impact: one line in `.gitignore`; prevents the scratch log from ever being swept into a commit.

### Fix-loop iter 1

Three validator findings applied, all under rule `spec.F4.claims-must-be-true`.

1. (warn) the class-name caveat in both the probe log and the upstream-report draft.
   Both said the `B` collision fires "before the parser-state bug can surface", which overstates it.
   Reworded: the collision masks the negative controls (the variants that should print `syntax OK`), while a reproducing file named `A`/`B` still dies with the parse death at the second class.
2. (warn) `.ai-sessions/lessons.md:102`, the same overstatement in the F4 correction addendum.
   Reworded to match: a control that should compile clean dies with the `@ISA` error instead of printing `syntax OK`; a reproducing file still shows the parse death first.
3. (info) `sdk/t/unit/attribute_handlers.t:144`, the in-eval `use Future::AsyncAwait`.
   Kept the line (it mirrors a real workflow module, which imports F::AA itself) and extended the comment to say it is redundant with the outer `require`, since either one alone reproduces.

Verification run before rewording, perl 5.038002, Future::AsyncAwait 0.71, no SDK modules loaded.
Reproducing file, classes named `A` and `B`, each with `method run :Run(...) ($i)`:

```
$ perl -c repro_AB.pl
repro_AB.pl syntax OK

$ perl -MFuture::AsyncAwait -c repro_AB.pl
Subroutine attributes must come before the signature at repro_AB.pl line 6.
```

Signature-less control, same `A`/`B` class names, which should print `syntax OK` under both:

```
$ perl -c ctl_AB_nosig.pl
ctl_AB_nosig.pl syntax OK

$ perl -MFuture::AsyncAwait -c ctl_AB_nosig.pl
Cannot create class B as it already has a non-empty @ISA at ctl_AB_nosig.pl line 6.
```

So the `B` collision suppresses only the control's `syntax OK`; the reproduction reports the parse death first, exactly as the validator said.

Redundancy check behind finding 3, three eval-string variants with no SDK modules:

```
inner-use-only:     ok=0 err=Subroutine attributes must come before the signature at (eval 1) line 7.
outer-require-only: ok=0 err=Subroutine attributes must come before the signature at (eval 6) line 6.
neither:            ok=1 err=
```

Either load path alone reproduces; with neither, the eval compiles.

### Fix-loop iter 2

The validator returned clean with one info: the `B` caveat as reworded is order-dependent.
With `B` as the second probe class the parse death wins, but with `B` first the `@ISA` error masks the reproduction as well, so probe classes must never be named `B` at all.
Applied at finalize while copying the draft forward, in both the upstream-report caveat and the probe record above.

## Key Actions

- Read the Fable review block on b510bd9, then re-ran the I18 probe with no SDK modules loaded to confirm the transitive `Temporalio::Workflow` load was the source of the false "no F::AA" claim.
- Re-scoped the canary's TODO to the inner assertions and added the non-TODO `like` guard on the exact error text.
- Ran the four-file probe set (main reproduction plus three negative controls) plus the eval-string variant, and recorded exact output.
- Deleted the contradicting `lessons.md` sibling and folded a correction addendum onto the 2026-07-10 entry.
- Simulated a flip by forcing `$ok`/`$err` to the post-fix values and confirmed `Result: FAIL`.
- Applied two warns and one info in fix iter 1, and the iter-2 ordering info at finalize.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F4 implement) | Executed plan.md Section 6 Step F4 sub-steps 1-8 | Dirty tree, both suites green, zero "TODO passed" lines, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: two claims-must-be-true overstatements, one info |
| Executor `mode=fix`, iter 1 | Reworded the `B` caveat in the notes and lessons, extended the in-eval comment | Applied 3, deferred 0, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean` with one ordering info |
| Executor `mode=finalize` | Session summary carrying the corrected draft, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Re-running the probe with zero SDK modules loaded, rather than trusting the I18 write-up, exposed the transitive F::AA load in one command.
- Simulating the flip (forcing the post-fix values) proved the alarm actually fires, instead of asserting that it would.

**What could improve:**

- The first probe pass burned a round trip on the `B` class-name collision.
  Naming probe classes after single-letter core modules is an avoidable trap and the review's generic "two classes" phrasing invited it.

**Course corrections:**

- The plan pointed at "lessons.md line 5"; the file had rotated and both relevant entries had moved.
  Located by opening text instead of line number.

## Process Improvements

- An isolation probe for a "does X require module M" question must load nothing but M.
  An SDK module in the probe can import M at any line, and the probe will report the opposite of the truth with no visible symptom.
- When a canary is marked TODO, check where the TODO boundary sits.
  A TODO around the whole subtest makes the top-level TAP line identical before and after the fix, which is exactly the state the canary exists to distinguish.
- A commit body is immutable, so a correction to a claim it makes has to land somewhere durable and findable: code comments, `lessons.md`, and the session summary, all three.

## Observations

- The bug's own diagnostic misdirects: it names a construct whose attribute already precedes its signature, at a line that is not where the poisoning happened.
- Two of the three claims corrected here were wrong in the same direction, toward making the bug look more fundamental (core perl, no dependency) than it is.
  A probe that loads too much biases exactly that way.
- `grep -c "TODO passed"` over prove output is a cheap suite-wide invariant.
  It catches any canary in the repo that has quietly started passing.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F5 re-vendors cloud, test, and health protos from the pinned sdk-rust tag, which is Temporal-version-sensitive work.
