# Session Summary: Goal Step 36 — determinism primitives (random reseed, replay-aware logger, patching) (P3.8)

**Date**: 2026-06-13
**Duration**: ~35 minutes (single autonomous subagent dispatch)
**Estimated Cost**: moderate (<$3 — spec/proto/reference reads, two CPAN installs, one RED/GREEN/REFACTOR cycle, full live suite)
**Conversation Turns**: 1 orchestrator dispatch
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.8.1 RED through P3.8.3 Verify in one commit.
  The Runner now implements the three determinism-critical workflow facilities
  driven by activation jobs: deterministic re-seedable RNG, a replay-suppressed
  logger, and safe workflow versioning (patched/deprecate_patch).
- **Subagent dispatches**: this summary covers dispatch 36
- **Steps completed**: 3 of 3 P3.8 sub-items (P3.8.1–P3.8.3)

## Key Actions

- Confirmed scope against plan P3.8 + spec section 10.4 (replay-safety
  primitives) + 10.3 step 4 (NotifyHasPatch / UpdateRandomSeed job handling) +
  T-wf-9 / T-wf-10. Invoked the `temporal:temporal-developer` skill (confirms the
  versioning/determinism concepts; it is end-user guidance, not SDK internals —
  spec + sdk-python remain ground truth).
- **MUST-match semantics, cross-checked against sdk-python
  `worker/_workflow_instance.py`:**
  - RANDOM: `self._random = random.Random(det.randomness_seed)` at init;
    `_apply_update_random_seed` calls `self._random.seed(job.randomness_seed)`
    (line 1102-1105). The seeding SOURCE is the activation's `randomness_seed`
    field (NOT the run id) — spec section 10.4 explicit. The spec mandates
    `Math::Random::ISAAC::XS` as the PRNG primitive.
  - LOGGER (T-wf-9): sdk-python `LoggerAdapter.isEnabledFor` returns false when
    `not log_during_replay and is_replaying_history_events()` (workflow/_sandbox.py
    line 297-301), suppressing output during replay. Spec section 10.4 adds the
    Perl-specific contract: the `is_*` predicates ALWAYS return true (so user
    code can build messages) but OUTPUT is discarded while is_replaying.
  - PATCHING: `workflow_patch(id, deprecated)` (line 1354-1368) —
    `use_patch = not self._is_replaying or id in self._patches_notified`,
    MEMOIZED in `_patches_memoized` (a prior answer wins, even when deprecating,
    and skips re-emitting the marker), emits `SetPatchMarker { patch_id,
    deprecated }` when use_patch. `_apply_notify_has_patch` adds the id to
    `_patches_notified` (line 793-796). Marker/notify protocol matched verbatim.
  - is_replaying: the runner already set `$is_replaying` from
    `$activation->is_replaying` (P3.3); both logger and patching read it.
- Protos verified verbatim: `UpdateRandomSeed { randomness_seed:uint64 }`,
  `NotifyHasPatch { patch_id:string }` (workflow_activation.proto 272/307),
  `SetPatchMarker { patch_id:string, deprecated:bool }` (workflow_commands.proto
  229).
- Installed the two spec-mandated deps into `~/perl5` local::lib:
  `Math::Random::ISAAC::XS` (1.004) and `Log::Any` (1.720, ships Log::Any::Test).
  `Log::Any` was already in cpanfile; added `Math::Random::ISAAC::XS` to
  `sdk/cpanfile`.
- RED (P3.8.1): `sdk/t/replay/determinism.t` — 5 subtests: UpdateRandomSeed
  reseed (deterministic before/after split across two activations),
  logger replay-suppression (T-wf-9, captured via Log::Any::Test adapter on the
  `Temporalio::Workflow` category), patched() live (one SetPatchMarker despite
  two calls — memoization), patched() during replay honouring NotifyHasPatch
  (absent vs present), and NotifyHasPatch recording the id in workflow info.
  Three fixtures added: `WfDef::RandomReseeder`, `WfDef::Logger`, `WfDef::Patcher`.
- GREEN (P3.8.2):
  - `lib/Temporalio/Workflow/Logger.pm` — NEW. Wraps a Log::Any logger; each
    level method (info/warn/error/...) forwards only when `!is_replaying`; the
    `is_*` predicates always return 1; carries workflow run_id/type context.
  - `lib/Temporalio/Workflow/Commands.pm` — added `set_patch_marker($id, $dep)`.
  - `lib/Temporalio/Workflow/Runner.pm` — swapped the placeholder xorshift `_RNG`
    package for `Math::Random::ISAAC::XS` in `_make_rng`; added `%patches_notified`
    + `%patches_memoized` fields, `_apply_update_random_seed` (re-`_make_rng`),
    `_apply_notify_has_patch` (records the id), the `patched($id, %opts)` method
    (memoize + use_patch + emit marker), a lazy `logger` accessor, and `patches`
    in `info`. Wired both new job variants into `_apply_job`.
  - `lib/Temporalio/Workflow.pm` — added the `logger`, `patched`, and
    `deprecate_patch` functional-surface entries.
- REFACTOR: POD on Runner (Determinism section now describes ISAAC + logger +
  patching), Logger module POD, Commands set_patch_marker doc.
- Verify: `prove -lj4 t/replay/determinism.t` → 5 subtests, exit 0; full
  `prove -lj4 t` → 37 files / 226 tests, exit 0 (integration ran LIVE against
  the dev server).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.8 — determinism: random reseed + replay-aware logger + patching; MUST-match vs sdk-python `_workflow_instance.py`) | Read latest summary + plan P3.8 + spec section 10.4/10.3 + the random/logger/patch protos; cross-checked sdk-python workflow_patch/_apply_notify_has_patch/_apply_update_random_seed/LoggerAdapter; installed ISAAC + Log::Any; built RED (5 subtests, 3 fixtures); added Logger class + set_patch_marker command + Runner handlers/patched/logger + functional surface; full live-suite verify; todo update; summary; commit; push | Suite 37 files / 226 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The two-activation RandomReseeder fixture (draw, sleep, reseed-on-fire, draw)
  proved both determinism AND that UpdateRandomSeed actually changes the stream,
  in one subtest — no need for a separate ad-hoc reseed unit test.
- The Patcher fixture calling patched() twice with the same id verified the
  memoization (one marker) and the deterministic answer in a single body.

**What could improve:**
- The first GREEN attempt put the Log::Any field `$logger` directly inside the
  typeglob-assigned level closures, which `feature 'class'` rejects ("Field is
  not accessible outside a method"). Should have routed through `$self->base_logger`
  from the start — a field is only visible inside a `method`, never inside a
  file-scope sub installed via glob.

## Process Improvements

- When generating per-level methods via typeglob inside a `feature 'class'`
  block, the installed subs are NOT methods and cannot close over fields —
  they must reach state only through `$self->accessor`. Plan the closures around
  public accessors up front.

## Observations

- `Math::Random::ISAAC::XS` has no in-place reseed (only `new`), so
  UpdateRandomSeed replaces the generator object with a freshly-seeded one. This
  is equivalent to sdk-python's `self._random.seed()` for the determinism
  contract: subsequent draws are seeded purely from the new value.
- `Log::Any::Test` pulls in `Test::Builder`, which emits a benign
  "Test::Builder was loaded after Test2 initialization" warning in
  determinism.t. The test still produces valid TAP and passes; left as-is rather
  than reorder imports (the warning is cosmetic and Log::Any::Test is the spec's
  canonical capture mechanism for T-wf-9).
- The patched() memoization mirrors sdk-python exactly: a prior answer wins even
  when a later call passes deprecated=1, and no second SetPatchMarker is emitted
  — so the patch decision is stable and the command appears at most once.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — usage-level confirmation of end-to-end
  workflow/activity/worker semantics for P3.9 (the Phase 3 acceptance gate:
  a real Perl worker running a workflow + activity against the dev server,
  plus the hello-world example). It is NOT SDK-internals ground truth — for
  P3.9 the ground truth is spec section 10.7 / 11 + the sibling reference SDKs'
  end-to-end examples.
