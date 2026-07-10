# Session Summary: Goal Step 31 — Workflow Runner skeleton + replay harness (P3.3)

**Date**: 2026-06-13
**Duration**: ~30 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (<$2 — several spec/proto reads, one RED/GREEN
cycle with a handful of debugging iterations, full live suite run)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.3.1 RED through P3.3.4 Verify in one commit.
  The CORE of the SDK now exists: `Temporalio::Workflow::Runner` is the custom
  deterministic scheduler that applies activation jobs, runs the workflow body
  under a dynamically-scoped CURRENT pointer, and drains commands into a
  completion proto — NEVER via IO::Async or the wall clock.
- **Subagent dispatches**: this summary covers dispatch 31
- **Steps completed**: 4 of 4 P3.3 sub-items (P3.3.1–P3.3.4)

## Key Actions

- Confirmed scope against plan P3.3 + spec section 10.3 (steps 1-2, 5-7; no
  pending-Future jobs yet) + section 10.6 harness. Activity scheduling (P3.4),
  timers (P3.5), dispatcher cache/eviction (P3.6), and the full
  fail/cancel/task-fail/continue-as-new outcome table (P3.7) are deliberately
  deferred — the skeleton handles only InitializeWorkflow + the success outcome.
- **Proto-name correction (P0.11 note honored):** the plan/spec prose says
  `start_workflow`, but the vendored coresdk proto's job variant is
  `initialize_workflow` (`WorkflowActivationJob.initialize_workflow`,
  field 1). Used the real variant name in the test + runner.
- **Determinism ground truth (CLAUDE.md MUST-match), cross-checked:**
  sdk-python `temporalio/worker/_workflow_instance.py` `activate()` /
  `_run_once()` drive the deterministic event loop and resolve futures
  imperatively from jobs; `now()` reads the activation timestamp, `random` is
  seeded from `randomness_seed` (not the run id). The Perl mechanism differs
  (no asyncio): the runner sets `$Temporalio::Workflow::Runner::CURRENT` via
  `Syntax::Keyword::Dynamically` around the body and reads time/seed/replay
  flag from the activation. The DETERMINISM guarantees match; the host
  primitive differs.
- RED (P3.3.1): `sdk/t/replay/runner_basics.t` — 4 subtests:
  trivial-complete (T-wf-11: one InitializeWorkflow job -> one
  CompleteWorkflowExecution command with the converted result);
  now/time/is_replaying/info from the activation (WfDef::Clock fixture);
  NoRunner raised by every context fn called outside a body; seeded RNG
  determinism (T-wf-10: same seed -> same sequence, different seed ->
  different sequence). Two fixtures in `t/lib/WfDef/` (Constant, Clock) —
  one `:isa` class per file under Future::AsyncAwait (lessons.md).
- GREEN (P3.3.2):
  - `lib/Temporalio/Workflow/Runner.pm` — `process_activation` skeleton
    (context set; jobs applied under dynamically-scoped CURRENT; pump;
    completion build), `_apply_initialize` (seed RNG, convert args,
    instantiate class, kick off `:Run`), context accessors
    (`activation_time`/`is_replaying`/`random`/`info`/`run_id`), plus a
    self-contained 32-bit xorshift `_RNG` package.
  - `lib/Temporalio/Workflow/Commands.pm` — `complete_workflow_execution`,
    `fail_workflow_execution`, `cancel_workflow_execution` builders over the
    `WorkflowCommand` oneof proto.
  - `lib/Temporalio/Test/WorkflowReplay.pm` — `push_activation` harness per
    spec section 10.6; decodes the completion and returns the command list.
  - Extended `lib/Temporalio/Workflow.pm` with the section-10.2 replay-safety
    surface: `now` (DateTime), `time`, `is_replaying`, `random`, `info`, each
    raising `Temporalio::Exception::Workflow::NoRunner` outside a body.
  - Added `requires 'DateTime';` to `sdk/cpanfile` (now() returns a DateTime).
- REFACTOR (P3.3.3): pump loop documented + structured per section 10.3 — no
  IO::Async, no wall clock; the skeleton's only Future is the main run Future,
  which Future::AsyncAwait resolves synchronously for a body with no pending
  workflow Futures. The `pending_futures` drive loop arrives with P3.4/P3.5.
- Verify (P3.3.4): targeted file green (4 subtests), then full suite
  `prove -lj4 t` -> 32 files, 196 tests, exit 0 (integration ran LIVE against
  the dev server, not skipped).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.3 Runner core + replay harness); confirm command/activation proto shapes vs spec 10.3 and coresdk protos; quiesce detection; determinism from activation not wall-clock | Read latest summary + plan P3.3 + spec 10.2/10.3/10.6; inspected coresdk workflow_activation/commands/completion protos; built RED replay test (4 subtests) + 2 fixtures; wrote Runner.pm + Commands.pm + WorkflowReplay.pm + Workflow.pm context surface; debugged 4 issues; full-suite verify; todo update; summary; commit; push | Suite 32 files / 196 tests, exit 0 |

## Efficiency Insights

**What went well:**
- Reading the actual coresdk protos (not trusting the plan's `start_workflow`
  prose) caught the `initialize_workflow` variant name up front.
- Recognizing that `Math::Random::ISAAC::XS` is NOT installed and that the RNG
  primitive is formally a P3.8 concern — implemented a self-contained
  deterministic generator for the T-wf-10 seed test rather than adding an
  uninstalled dep and breaking the suite.

**What could improve:**
- Burned two iterations on the RNG: first a 64-bit SplitMix64 (Perl's native
  `*` overflows to a double past 2**53 and silently drops the low bits ->
  constant output), then settled on a 32-bit xorshift (XOR + shifts only,
  exact in native Perl ints). Should have reached for shift/XOR-only from the
  start given Perl's float-promotion on big-int multiply.
- The initial test asserted `json/plain` for the result, but a non-UTF-8 Perl
  string is `binary/plain` per spec 5.2 (BinaryPlain wins ahead of Json in the
  composite). Fixed the assertion to match the real (correct) converter
  contract. Verify the converter behavior before asserting an encoding.

**Course corrections:**
- `our $CURRENT` in a no-`package` file lands in `main::`, but the functional
  surface reads `$Temporalio::Workflow::Runner::CURRENT`. Fixed by declaring it
  inside an explicit `package Temporalio::Workflow::Runner { our $CURRENT; }`
  block and using the fully-qualified name in the `dynamically` statement.
- A proto built via `->new` from a nested hashref leaves sub-messages as plain
  hashrefs (no accessors, no `which_variant`). Round-tripping through
  encode/decode in the harness materializes the fully-blessed proto the worker
  actually receives off the wire — applied to BOTH the inbound activation and
  the outbound completion.

## Process Improvements

- For deterministic integer math in Perl, prefer shift/XOR-only generators
  (xorshift) over multiply-based ones (SplitMix/PCG): native `*` promotes to a
  double past 2**53 and silently corrupts a 64-bit modular multiply. If a
  64-bit multiply is truly needed, `use integer` (signed modular) or a
  32x32->64 split is required.
- When a `feature 'class'` module needs a package variable read from elsewhere
  AND the file has no leading `package` statement, wrap the `our` in an
  explicit `package Name { our $VAR; }` block — a bare `our $VAR` lands in
  whatever the ambient package is (often `main`).

## Observations

- Quiesce detection for the skeleton is trivial: with no pending workflow
  Futures, Future::AsyncAwait runs the `async :Run` body synchronously to
  completion at call time, so `$main_run_future->is_ready` is already true
  when the pump runs. The real pump loop (drive ready continuations until no
  progress) is only exercised once P3.4 activities / P3.5 timers introduce
  unresolved `Temporalio::Workflow::Future`s the runner resolves from jobs.
- `_build_completion` currently re-raises a run-body exception rather than
  mapping it — the full outcome decision table (task-fail vs workflow-fail vs
  cancel vs continue-as-new) is explicitly P3.7. The skeleton never silently
  swallows an error.
- The harness drives ONE run per instance (run_id seeded on first
  push_activation; reused on subsequent calls) — mirrors Python's
  WorkflowReplayer over a single run. The multi-run dispatcher cache is P3.6.

## Suggested Skills for Next Session

- No matching skill for the next step (P3.4: `execute_activity`/`start_activity`
  + `ScheduleActivity` command emission + `pending_activities` seq map +
  `ResolveActivity` job handling + `Exception::Activity` at the await site).
  Ground truth for P3.4: spec section 10.2 execute_activity kwargs + section
  10.3 seq allocation, and sdk-python `_workflow_instance.py`
  `_apply_resolve_activity` / `workflow.execute_activity` for the
  schedule->resolve round trip and out-of-order seq resolution. The
  `temporal:temporal-developer` skill is end-user usage guidance, not SDK
  internals.
