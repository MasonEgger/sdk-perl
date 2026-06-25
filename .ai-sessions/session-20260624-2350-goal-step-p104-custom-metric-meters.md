# Session Summary: custom metric meters (P10.4, spec section 28.2)

**Date**: 2026-06-24
**Duration**: ~2 hours
**Conversation Turns**: 1 (autonomous bpe:step-executor dispatch)
**Estimated Cost**: ~$8-10 (Opus, two Alien reinstalls + repeated cargo builds + full -lj4 suite + xt + extensive SEGV bisection)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: Implement P10.4 (custom metric meters — the 8-callback
  TemporalCoreCustomMetricMeter set), shim-touching; cargo test green, full
  `prove -lj4 t` exit 0, pushed to origin/v1.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: 1
- **Subagent dispatches**: 1 (this one)
- **Steps completed**: 1 of 1 (P10.4.1/.2/.3 checked off)

## Key Actions

- Shim (ext/temporalio-perl-bridge/src/lib.rs): added the custom-metric-meter
  surface. A process-global `MeterRegistry` (compare-and-set `active` flag for
  the single-owner rule) holds a shim-allocated handle-id counter, a parked
  create/free request queue (`VecDeque<MeterRequest>`), and an aggregation table
  (`HashMap<(metric_id, attrs_id), (kind, sum, count)>`). The eight callbacks:
  `metric_record_integer/float/duration` aggregate in PURE RUST on the calling
  core thread (zero Perl contact); `metric_new`/`attributes_new`/`*_free`
  allocate a handle id, park a request, and RETURN THE ID IMMEDIATELY (never
  block, never call Perl). The main-thread drain runs the Perl
  `create_metric`/`new_attributes`/free (binding the shim id) and pulls
  aggregated record buckets. cbindgen excludes the three
  TemporalCoreCustomMetricAttribute* types (header forward-typedef only).
- KEY DESIGN DECISION (spec section 28.2 spike, M3): the first design used a
  Perl reentrant-runner CLOSURE the shim called inline on the main thread. It
  crashed (SEGV) nondeterministically on the SECOND nested invocation — libffi
  corrupts on repeated nested FFI-closure re-entry. Replaced with the
  shim-allocates-id-and-parks design: thread-agnostic, never blocks, never calls
  Perl from a callback, so neither self-deadlock nor nested re-entry can occur.
  This satisfies the spike (a main-thread metric_new is safe) by construction.
- KEY BUG FIXED (the second SEGV, even with no metric_new): core RETAINS the
  TemporalCoreCustomMetricMeter struct by pointer for the runtime's lifetime
  (header: "freed by a callback within itself"), but Runtime's `@keep` was
  dropped right after `runtime_new`, leaving core a dangling pointer ->
  nondeterministic crash. Fix: Runtime moves `@keep` into a `$telemetry_keep`
  field when a meter is configured, releasing it only AFTER `runtime_free`.
- cargo test: 9 meter tests (park+return-id, 8-thread exact aggregation with
  zero Perl contact = T-meter-7, record kinds bucketing, null-metric drop,
  attribute decode of all value types, single-owner, off-thread parks too) +
  header-contract symbols. 24/24 cargo tests green.
- Regenerated the cbindgen header and rebuilt the installed
  `Alien::Temporalio::PerlBridge` TWICE (once per shim ABI change: the
  closure->park redesign), via `dzil build --no-tgz` + `cpanm --reinstall` with
  `ALIEN_TEMPORALIO_PERL_BRIDGE_EXT_PATH`. Verified the new meter symbols via
  `nm -D` and confirmed NO undefined `temporal_core_*` externs in the cdylib.
  All cargo/Alien builds CARGO_BUILD_JOBS=2, foreground.
- Perl SDK: new `Temporalio::Runtime::MetricMeter` (duck-typed/subclassable
  Ruby-shaped meter: `create_metric`/`record_integer`/`record_float`/
  `record_duration`/`new_attributes`, a `Kind` constants package, the
  process-global active-meter registry + shim-id handle tables + the
  `_run_request`/`_apply_record` drain dispatch, throwing-method isolation);
  `TelemetryConfig` accepts a MetricMeter as the third mutually-exclusive
  exporter (extended T-rt-4 -> T-meter-2) and `to_ffi` builds the 8-pointer
  `CustomMetricMeter` record; `FFI.pm` gains the `CustomMetricMeter`/`MeterRecord`
  records, the meter attachments, and `meter_callback_ptrs`/
  `byte_array_ref_to_scalar` helpers; `Callback.pm` drains the meter request
  queue (run+bind) then the aggregated record buckets on each wakeup;
  `Runtime.pm` claims/releases the meter registry, sets/clears the active meter,
  and retains the meter struct.
- sdk/t/unit/metric_meter.t: T-meter-1..6,8,9 + single-owner (drives the shim
  callbacks directly on the main thread through a registered runtime).
- sdk/t/integration/metrics.t: T-meter-10 — a live worker runs a workflow under
  a CountingMeter and asserts core created+recorded metrics through it; explicit
  teardown (P7.2 precedent) so the -j4 harness never wedges.
- Verified: cargo 24/24; full `prove -lj4 t` 444 tests exit 0 (metrics.t RAN,
  not skipped — dev server present); `prove -lj4 xt` (POD) green after
  documenting TelemetryConfig->custom_meter.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute P10.4 (custom metric meters), shim-touching, memory guard, one commit | shim 8-callback meter set (aggregate + park-id), header regen, 2x Alien reinstall, MetricMeter + TelemetryConfig custom_meter + Callback drain + Runtime registry/retain, RED/GREEN both layers, SEGV bisection x2 | cargo 24/24, suite 444 green |

## Efficiency Insights

**What went well:**
- The 8-thread cargo aggregation test (T-meter-7) and the direct-drive unit
  tests pinned the record path before the live integration test, so the
  end-to-end run was green on the first try once the two SEGVs were fixed.

**What could improve:**
- The reentrant-closure design cost a full Alien rebuild + bisection before the
  libffi nested-re-entry crash surfaced its root cause. Reaching for the
  shim-allocates-id-and-parks design first (no Perl-from-callback at all) would
  have avoided it — the spike's "run inline" wording nudged toward the closure.

**Course corrections:**
- Replaced the inline reentrant FFI closure with shim-allocated ids + a parked
  request queue after the nested-re-entry SEGV.
- Added `$telemetry_keep` after discovering core retains the meter struct.

## Process Improvements

- For a shim struct core RETAINS by pointer past the constructing FFI call
  (custom_meter; anything the C header says is "freed by a callback within
  itself"), the Perl `@keep` MUST be promoted to an object field, not dropped
  after the constructor returns.
- Avoid invoking a Perl (FFI::Platypus) closure synchronously from inside a
  shim callback that is itself reached through an FFI call — nested re-entry
  corrupts libffi on repeated calls. Park + drain on the main thread instead.

## Observations

- `MeterRecord` is 40 bytes (metric_id 0, attributes_id 8, record_kind 16 +7
  pad, value 24, count 32) — Perl `record_layout_1` and the C `#[repr(C)]` must
  stay byte-identical or the record-drain stride corrupts every slot.
- The Callback drain runs parked CREATE requests BEFORE record buckets in the
  same cycle, so a metric recorded in the cycle it was created is already bound;
  cross-cycle the bind already landed. Unbound/disabled ids drop their records.

## Suggested Skills for Next Session

- None required. Next step is P10.5 (worker versioning, spec section 29.1):
  DeploymentVersion canonical-string, the WorkerOptions versioning union
  (464-byte tripwire), and the `:VersioningBehavior` workflow attribute. Pure
  Perl + WorkerOptions packing (NOT shim-touching). temporal-developer helps
  only if deployment-routing semantics come up.
