# Session Summary: P10.8 workflow determinism guard

**Date**: 2026-06-25
**Duration**: ~40 minutes
**Conversation Turns**: 1 (autonomous bpe:step-executor dispatch)
**Estimated Cost**: ~$3 (Opus, heavy reference reading + full suite x2)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: P10.8 (determinism_guard + WfDef fixtures, T-det-1..7) lands; full `prove -lj4 t` green; committed + pushed to origin/v1
- **Mode**: step
- **Outcome**: converged (step complete)
- **Subagent dispatches**: 1 (this one)
- **Steps completed**: 3 of 3 (P10.8.1, P10.8.2, P10.8.3)

## Key Actions

- RED: wrote `sdk/t/unit/determinism_guard.t` (8 subtests covering T-det-1..7) plus six WfDef fixtures (IllegalTime, IllegalRand, SafeNow, UnsafeEscape, IllegalHiRes, CoreQualified). Confirmed it failed with the missing-module error.
- GREEN: created `sdk/lib/Temporalio/Workflow/DeterminismGuard.pm` (process-global CORE::GLOBAL:: overrides for time/localtime/gmtime/rand/srand/sleep + Time::HiRes::{time,gettimeofday,sleep} symbol-table overrides, gated on `defined $Runner::CURRENT` and `$SUPPRESS_DEPTH == 0`).
- Added `illegal_call_tracing_disabled` to `Workflow/Unsafe.pm` (dynamically-scoped suppression of the new `$DeterminismGuard::SUPPRESS_DEPTH`, never `local`).
- Routed a Nondeterminism escaping `:Run` through the same task-vs-workflow-fail decision as a recorded one (new branch in `Runner::_outcome_for_failure`, before the generic Temporal-failure branch).
- Wired the `disable_determinism_guard` worker kwarg (default OFF; the worker installs the guard in ADJUST unless set).
- Scrubbed em-dashes from all new files (one was in a Test2 message string and produced a real "Wide character in print" warning).
- Verified: full `prove -lj4 t` green (80 files, 496 tests), xt POD tests green (296).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute P10.8 (determinism guard) per system prompt | TDD RED/GREEN/REFACTOR, wired worker kwarg + runner routing, scrubbed dashes, ran full suite | All green; committed + pushed |

## Efficiency Insights

**What went well:**
- Reading the Ruby `default_illegal_workflow_calls` set + the spec M2 narrowing decision up front kept the override set correct (time/entropy only, no IO/process builtins).
- Driving the guard through the existing `WorkflowReplay` harness (which sets `$Runner::CURRENT` via `dynamically`) meant no bespoke test scaffolding for "in workflow context".

**What could improve:**
- Hit a prototype snag twice: first `(;$)` parsed as a signature under `use v5.38` (fixed with `no feature 'signatures'`), then `set_prototype` rejected a variable arg (fixed by hardcoding the three Time::HiRes prototypes). Could have anticipated both from the start.

**Course corrections:**
- Initial Time::HiRes override copied the prototype dynamically via `set_prototype`; switched to literal `sub ()` / `sub (;@)` to kill the "Prototype mismatch" warnings cleanly.

## Process Improvements

- For CORE::GLOBAL:: / builtin overrides under `use v5.38`, reach for `no feature 'signatures'` + classic prototypes immediately; signatures and prototypes share the `(...)` slot.

## Observations

- A Nondeterminism thrown from the body (not recorded via `_record_nondeterminism`) needed an explicit branch in `_outcome_for_failure`: it isa `Temporalio::Exception`, so the generic branch would otherwise have failed the WORKFLOW instead of the task.
- `CORE::time` inside a workflow is deliberately NOT trapped (T-det-7) - the documented best-effort gap, since CORE::-qualified calls bind the builtin directly.

## Suggested Skills for Next Session

- None specific. P10.9 (workflow reset + http_proxy) is pure-Perl FFI-record + proto round-trip work; no shim/cargo, no special skill needed.
