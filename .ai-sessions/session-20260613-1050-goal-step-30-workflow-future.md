# Session Summary: Goal Step 30 — Workflow::Future (P3.2)

**Date**: 2026-06-13
**Duration**: ~15 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (<$1 — a couple reference-SDK reads, one RED/GREEN
cycle with no debugging detour, full-suite run)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.2.1 RED through P3.2.3 Verify in one commit.
  `Temporalio::Workflow::Future` now exists as the core primitive of the
  custom deterministic workflow scheduler: a subclass of the CPAN `Future`
  module that the runner (P3.3, next step) resolves imperatively from
  activation jobs, never via IO::Async timers.
- **Subagent dispatches**: this summary covers dispatch 30
- **Steps completed**: 3 of 3 P3.2 sub-items (P3.2.1–P3.2.3)

## Key Actions

- Confirmed the integration approach against spec section 10.3: the class is a
  plain `Future` subclass (`use parent -norequire, 'Future'`), NOT a
  `feature 'class'` class — `Future` is a classic blessed-hashref module and
  `class :isa(...)` cannot extend it. This also sidesteps the lessons.md
  toolchain gotcha (only one `class :isa(...)` parses per file with
  Future::AsyncAwait loaded) — no `class` keyword is used here at all.
- Verified the three load-bearing behaviors empirically before writing the
  module (one-off `perl -e`), so the contract was nailed down up front:
  - **Manual resolve runs continuations synchronously** — `Future`'s
    `on_ready` callbacks (which are exactly the continuations
    `Future::AsyncAwait` registers for an `await`) run synchronously inside
    `->done` / `->fail`. So calling `->done` from the runner makes awaiting
    workflow code runnable immediately with no event-loop trip — the basis of
    the deterministic pump (spec section 10.3 pump loop).
  - **on_cancel reverse-registration order** — `Future`'s real `on_cancel`
    API fires hooks last-registered-first on `->cancel`. Verified output
    `c b a` for registration order `a b c`. Spec section 10.3 pins this for
    nested cancellation chains (a hook emitting `CancelActivity`/`CancelTimer`/
    `RequestCancelExternalWorkflowExecution` runs before earlier-registered
    cleanup that depends on it).
  - **`is_workflow_future`** returns true; interceptors use it to distinguish
    these from ordinary client-created Futures.
- MUST-match determinism semantics cross-checked against reference SDK source
  per CLAUDE.md (quoted):
  - sdk-python `temporalio/worker/_workflow_instance.py`: the instance owns a
    `self._ready: deque[asyncio.Handle]` (line 279) pumped by `_run_once`
    (line 2482, `while self._ready: ... handle = self._ready.popleft()`),
    and resolves futures imperatively with `fut.set_result(...)` /
    `fut.set_exception(...)` (lines 1027/1031/1051/1055, 1122) inside
    `_apply_resolve_*` job handlers (e.g. `_apply_resolve_activity` line 810,
    `handle._resolve_success(ret)` line 841). Python replaces the asyncio
    event loop with the workflow instance itself
    (`asyncio._set_running_loop(self)` line 2484) so all scheduling is
    deterministic and driven by activation jobs, not wall-clock timers.
  - The Perl mechanism differs (no asyncio): there is no replaced loop;
    instead `Future`'s synchronous `on_ready` semantics give the same
    "resolve a future -> its awaiters become immediately runnable in a
    defined order" guarantee. The DETERMINISM and ordering guarantees match;
    the runner (P3.3) will own the analog of `_ready`/`_run_once` as its pump
    loop over `pending_futures + main_run_future` (spec section 10.3).
  - sdk-ruby workflow executor uses fibers driven by the worker rather than a
    real scheduler — same imperative-resolution principle, different host
    primitive. (Did not need to quote a specific ruby line for this Future-only
    step; the resolution-from-jobs pattern is the shared invariant.)
- RED (P3.2.1): `sdk/t/unit/workflow_future.t` — 5 subtests: Future-subclass +
  `is_workflow_future` true + fresh-pending; synchronous `on_ready` during
  `->done` (with resolved result); synchronous `on_fail` during `->fail`
  (failed state); `on_cancel` reverse-registration order on `->cancel`;
  `->new` called as an instance method returns a same-class instance (so the
  runner can keep driving chained/dependent futures).
- GREEN (P3.2.2): `sdk/lib/Temporalio/Workflow/Future.pm` — minimal:
  `use parent -norequire, 'Future'` plus `sub is_workflow_future { 1 }`, with
  full POD documenting the manual-resolve / reverse-cancel-order contract and
  the deliberate non-use of `feature 'class'`.
- Verify (P3.2.3): targeted file green (5 subtests), then full suite
  `prove -lj4 t` -> 31 files, 192 tests, exit 0 (integration ran live, not
  skipped).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.2 Workflow::Future), verify manual resolve + on_cancel ordering against spec 10.3 and reference SDK determinism source, keep scope to the Future (runner is P3.3) | Read latest summary + plan P3.2 + spec 10.3; ground-truth reads of python `_workflow_instance.py`; empirical `perl -e` proof of Future subclass behaviors; RED unit test (5 subtests); GREEN minimal module + POD; targeted + full-suite verify; todo update; summary; commit; push | Suite 31 files / 192 tests, exit 0 |

## Efficiency Insights

**What went well:**
- A 10-line `perl -e` proving on_ready-sync, on_cancel-reverse-order, and
  subclass-`new` BEFORE writing the module made the test assertions exact and
  the GREEN module correct first try — zero debugging.
- Recognizing immediately that `Future` (blessed hashref) requires
  `use parent`, not `feature 'class'`, avoided the known one-`class`-per-file
  toolchain trap entirely.

**What could improve:**
- Fat-fingered a subtest terminator (`};` instead of `});`) in the first
  draft of the test file; caught it on inspection before running. Closing a
  `T2->subtest(...)` is `});` — quick self-check pays for itself.

## Process Improvements

- For a pure CPAN-Future subclass, prove the inherited behaviors you depend on
  with a throwaway `perl -e` first; the subclass surface (on_ready timing,
  on_cancel ordering, `new` returning the subclass) is the actual contract and
  is far cheaper to confirm empirically than to reason about.

## Observations

- `Temporalio::Workflow::Future->new` and `$instance->new` both return a
  `Temporalio::Workflow::Future` (Future's `new` honors the invocant class),
  so the runner can construct dependent/chained futures without losing the
  workflow-future identity or the deterministic-resolution path.
- Scope was held strictly to the Future: no runner, no command buffer, no
  command-emitting on_cancel wiring yet — those land with P3.3+ where the
  runner installs the actual `CancelActivity`/`CancelTimer` hooks on these
  futures. This class only guarantees the ordering primitive they rely on.

## Suggested Skills for Next Session

- No matching skill for the next step (P3.3 Runner core + replay harness:
  `process_activation` skeleton, job ordering per spec 10.3 step 3, the pump
  loop over `pending_futures + main_run_future`, `Workflow/Context` via
  `Syntax::Keyword::Dynamically`, `Commands.pm`, and
  `Test/WorkflowReplay.pm`). The `temporal:temporal-developer` skill is
  end-user usage guidance, not SDK internals. Ground truth for P3.3: spec
  section 10.3 steps 1-2/5-7 + section 10.6 harness, and sdk-python
  `_workflow_instance.py` `_run_once` / `activate` for the pump and job
  ordering.
