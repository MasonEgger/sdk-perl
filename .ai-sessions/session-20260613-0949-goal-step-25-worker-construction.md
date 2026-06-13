# Session Summary: Goal Step 25 — Worker construction + validate + shutdown (P2.2)

**Date**: 2026-06-13
**Duration**: ~30 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (<$1 — reference-SDK reads, one RED/GREEN cycle, two
  full-suite + integration runs)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P2.2.1 RED through P2.2.4 Verify in one
  commit. The worker can now be constructed (activity registry built,
  WorkerOptions marshalled), `validate`d against a live server, and shut
  down cleanly. Poll/run loops remain deferred to P2.4/P3.6.
- **Subagent dispatches**: this summary covers dispatch 25
- **Steps completed**: 4 of 4 P2.2 sub-items (P2.2.1–P2.2.4)

## Key Actions

- FFI signatures transcribed from the pinned C header (CLAUDE.md
  non-negotiable):
  - `temporal_core_worker_new(connection, *options) -> TemporalCoreWorkerOrFail`
    (returned BY VALUE; added the `WorkerOrFail` record + type alias to
    `Core/FFI.pm`, mirroring `RuntimeOrFail`).
  - `worker_validate` and `worker_finalize_shutdown` are async
    `(worker, user_data, callback)` over the `worker` callback kind
    (kind 2, fail-or-nothing — already in `Core::Callback`); `worker_initiate_shutdown`
    and `worker_free` are sync.
- MUST-match WorkerOptions defaults verified against reference SDK source and
  quoted: sdk-ruby `worker.rb` 447–465 (max_cached_workflows 1000, pollers
  simple_maximum 5, nonsticky_to_sticky_poll_ratio 0.2, sticky 10s,
  heartbeat throttle 60s/30s, graceful 0s, identity_override nil → client
  identity) and the FixedSize tuner default of 100 per slot
  (`worker/tuner.rb` 266–269). Reused the proven P0.10 hand-packed
  `Core::FFI::WorkerOptions` builder for real (no new marshalling).
- RED (P2.2.1): `sdk/t/unit/worker_new.t` — T-wkr-1 registry population +
  the kwargs→WorkerOptions echo through the P0.10 `debug_worker_options`
  shim (default config field-for-field, then explicit-kwarg overrides),
  plus Argument-on-empty-task_queue / missing-client / unknown-kwarg.
  RED (P2.2.2): `sdk/t/integration/worker_new.t` (DevServer-backed) — live
  validate + clean shutdown, a fresh-task-queue worker (T-wkr-5 shape), and
  idempotent shutdown.
- GREEN (P2.2.3): `sdk/lib/Temporalio/Worker.pm` — construction (activity
  registry via the P2.1 `ActivityRegistry`, workflows list stored for P3.1),
  `_build_worker_options` (seconds→millis, slots→FixedSize, build_id→None),
  lazy `_ensure_worker` → `worker_new` (Bridge on fail), async `validate`,
  idempotent `shutdown`.
- Verify (P2.2.4): unit green, integration green LIVE (Temporal CLI 1.6.2 at
  ~/.local/bin), full suite `prove -lj4 t` → 26 files, 157 tests, exit 0.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute P2.2 (Worker construction/validate/shutdown + FFI attaches), reuse P0.10 WorkerOptions, header-true signatures, MUST-match defaults vs sdk-ruby/rust, DevServer integration | Header reads (worker_new/validate/shutdown), ruby/rust default reads, RED unit+integration, GREEN Worker.pm + 6 FFI attaches + WorkerOrFail record, two test cycles, todo update, summary, commit, push | Suite 26 files / 157 tests exit 0; validate live-green; T-wkr-1/T-wkr-5 green |

## Efficiency Insights

**What went well:**
- The P0.10 WorkerOptions builder + the existing `worker` callback kind
  (kind 2) meant validate worked first try — no shim or marshalling changes.
- Quoting ruby's exact default lines up front made the kwargs→options echo
  assertions correct without iteration.

**What could improve:**
- First integration run deadlocked on `worker_finalize_shutdown`: the async
  finalize awaits core's `Worker::shutdown`, which blocks on
  `workflows.shutdown()` until the workflow poll loop returns ShutDown — and
  a never-run worker has no poll loop to drive it. Fixed by making P2.2
  shutdown initiate+free only (the graceful finalize sequence belongs in
  `run`, P2.4). Reading `sdk-core/src/worker/mod.rs:shutdown` (not just the
  bridge header) revealed the cause.
- First unit RED expected `build_id=''` for an undef build_id; an undef
  packs as a NULL ByteArrayRef, which the shim echoes as `<null>` — test
  expectation slip, not a code bug.

**Course corrections:**
- `class :param` dies with a plain-string "Unrecognised parameters" before
  ADJUST runs, so unknown-kwarg → Argument needed a glob wrapper around the
  generated `new` (same idiom P1.10 used for positional `new`); gave
  client/task_queue undef defaults so missing ones surface from ADJUST.

## Process Improvements

- For any sdk-core async lifecycle call, read the core `.rs` method (not just
  the bridge header) to learn what it AWAITS — `finalize_shutdown` blocks on
  poll-loop drain, which a construction-only worker can never satisfy.
- When a kwargs class needs Argument-on-unknown-param, wrap the generated
  `new` (capture `Class->can('new')`, redefine the glob) — `class :param`
  rejection happens before ADJUST and throws a plain string.

## Observations

- `worker_finalize_shutdown` is correctly issued from `run` once both poll
  loops have returned ShutDown (header comment at worker.rs:1009 confirms);
  P2.4 will add it. P2.2's `shutdown` returns a ready Future so
  `await $worker->shutdown` reads the same in both phases.
- The harmless `shutdown_worker rpc errored ... transport error` WARN during
  the integration run is the worker's ShutdownWorker RPC racing the dev
  server teardown — expected, not a failure.

## Suggested Skills for Next Session

- No matching skill for P2.3 (Activity::Context + heartbeat): it is
  `Syntax::Keyword::Dynamically` context scoping across an await (spec
  §16.1), the `worker_record_activity_heartbeat` sync FFI attach, and
  wrapping `coresdk.ActivityHeartbeat`. Reference ground truth: spec §9.3,
  sdk-python `temporalio/activity.py` context handling, and the existing
  `Core::Proto` resolve/encode path. The `temporal:temporal-developer`
  skill is end-user usage, not SDK internals.
