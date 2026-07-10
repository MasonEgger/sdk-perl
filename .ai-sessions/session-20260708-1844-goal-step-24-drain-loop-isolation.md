# Session Summary: R20 Per-Entry Exception Isolation in the Callback Drain Loop

**Date**: 2026-07-08
**Duration**: ~15 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one new subtest, one helper plus two guarded sites in Callback.pm, POD paragraph; pure Perl, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R20 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R20, finding L17: the completion drain loop had no per-entry exception isolation, so one dying continuation aborted the chunk loop and stranded every later completion)

## Key Actions

- Pinned the drifted spec line refs first: at the spec-writing commit, `Core/Callback.pm:322-331` was the entry dispatch loop in `drain` and `:463-467` was the Future settle in `_complete` (now :345-354 and :491-494 pre-fix).
The mechanism: `$record->{future}->done/fail` runs awaiter continuations synchronously; a die propagates out of `_complete`, out of the chunk `for` loop, and out of `loop_once`, losing the already-popped later entries in the drain buffer.
- RED: new callback.t subtest queues three worker_poll completions before the loop runs (one chunk), attaches a dying `on_done` to the middle future, and asserts the death does not propagate, entries 1 and 3 resolve (3 with its own payload), the dying future itself still settles done, and the death is logged.
Pre-fix it failed exactly as documented: the die propagated out of `await_or_timeout`, entry 3 was stranded, nothing logged.
- GREEN: added `_guard_entry($what, $code)` (one eval, warn-and-continue on death) and routed both drain sites through it: the per-entry `_complete` dispatch in `drain` (covers builder/cast deaths) and the fail/done settle in `_complete` (covers continuation deaths with a callback-id-labeled warning).
- REFACTOR landed with GREEN (the shared helper IS the factoring); comments cite L17/R20 at the helper and both call sites; POD DESCRIPTION gained the blast-radius contract paragraph (any death is one entry, never the chunk).
- Verify: `prove -lj4 t` green (144 files, 661 tests, up 1 subtest; integration live against the dev server), `prove -lj4 xt` green (318). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (R20) | Full RED/GREEN/REFACTOR for per-entry drain isolation (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Diffing Callback.pm at the spec-writing commit resolved the drifted line references in one step; the two cited ranges mapped cleanly to the two guard sites the plan wanted.
- The existing callback.t harness (trampoline-through-FFI with crafted ByteArrays) made the three-completions-one-chunk scenario a direct reuse; no new fixture code.

**What could improve:**
- Nothing notable; smallest remediation step so far.

**Course corrections:**
- Caught an em-dash in a code comment during self-review and replaced it before committing (global writing rule).

## Process Improvements

- When a plan step cites file:line ranges, resolve them against the commit that introduced the spec (`git show <spec-commit>~1:<path>`) instead of trusting current line numbers; remediation commits shift them every step.

## Observations

- The inner settle guard means the outer dispatch guard never sees continuation deaths; its remaining job is builder/cast deaths and future bridge-bug paths, which keeps the warning labels distinct (generic "completion entry dispatch" vs "callback N (kind K) continuation").
- Future.pm marks the future ready before running callbacks, so the dying entry's future still reports done; the test asserts this so nobody "fixes" it into a failed future later.
- Next unchecked step is R25 (send search_attributes and versioning_intent on continue-as-new, Runner.pm continue-as-new command builder, replay test).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R25 is continue-as-new command semantics; the proto field names and versioning_intent enum need checking against the vendored protos and reference SDKs.
