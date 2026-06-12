# Session Summary: Goal Step 7 — Temporalio::Core::FFI (P0.6)

**Date**: 2026-06-11
**Duration**: ~25 minutes (single autonomous subagent dispatch; bulk of time in dependency installation)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (~$1-2 — header reads, cpanm installs, short prove runs)
**Model**: claude-fable-5

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P0.6.1 RED through P0.6.4 Verify in one
  commit; step P0.6 is now fully checked off
- **Subagent dispatches**: this summary covers dispatch 7
- **Steps completed**: 4 of 4 P0.6 sub-items (P0.6.1–P0.6.4)

## Key Actions

- Environment prep (one-time, outside the repo): installed
  FFI::Platypus 2.11 into ~/perl5 via cpanm, then built both Alien dists
  with `dzil build` and installed the tarballs via cpanm — alien-core with
  `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH=../sdk-rust` (warm cargo build),
  alien-perl-bridge with `ALIEN_TEMPORALIO_PERL_BRIDGE_EXT_PATH` pointing
  at the in-tree crate (the cpanm build dir is outside the repo, so the
  walk-up-from-`__FILE__` locator cannot find it). Both Aliens now resolve
  `dynamic_libs` to installed share-dir cdylibs. Removed the dzil build
  artifacts afterward to keep the tree clean.
- Verified FFI mechanics empirically BEFORE writing code (throwaway /tmp
  spike, deleted): `record(Class)` without `*` passes/returns records BY
  VALUE — `temporal_core_runtime_new`'s by-value `TemporalCoreRuntimeOrFail`
  return works directly under Platypus 2.11, so the plan's shim out-param
  fallback was NOT needed. Also confirmed FFI::Platypus::Record does NOT
  support nested records, so `TemporalCoreLoggingOptions`' embedded
  ByteArrayRef is flattened to `filter_data`/`filter_size` fields
  (layout-identical: pointer + size_t + fn-pointer).
- RED (P0.6.1): created `sdk/t/unit/core_ffi.t` — T-ffi-1 (16 Phase-0
  wrapper subs present in the symbol table), T-ffi-2 (runtime_new/free
  round-trip with NULL telemetry + 0 heartbeat), T-ffi-3 (subprocess with
  both Alien modules masked by stubs returning a bogus lib path → load
  dies naming the attempted path). All 3 subtests failed (module absent).
- GREEN (P0.6.2): created `sdk/lib/Temporalio/Core/FFI.pm` — five record
  classes (ByteArrayRef, LoggingOptions, TelemetryOptions, RuntimeOptions,
  RuntimeOrFail) with layouts transcribed from the pinned C headers, seven
  opaque type aliases, `-f` existence check on every dynamic_libs path
  (die names the path + OS error), and the Phase-0 attach set with eager
  attach-or-die for version-skew detection at import time.
- REFACTOR (P0.6.3): GREEN already landed table-driven — `@phase0_attach`
  (C symbol, wrapper, args, ret) + one attach loop is exactly the plan's
  refactor target; verified by inspection, no restructuring needed.
- Verify (P0.6.4): `prove -lj4 t/unit/core_ffi.t` PASS; full suite
  `prove -lj4 t` green — 4 files, 15 tests, exit 0. Checked off
  P0.6.1–P0.6.4 in todo.md.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P0.6 Temporalio::Core::FFI), foreground builds, CARGO_BUILD_JOBS=2 memory guard | Installed FFI::Platypus + both Aliens, spike-verified record-value return, RED test, GREEN FFI.pm (table-driven attach), full-suite verify, session summary, commit, push | T-ffi-1..3 pass; full suite 15 tests green |

## Efficiency Insights

**What went well:**
- The /tmp mechanics spike (record-value return against the real library)
  resolved the plan's flagged Platypus risk in one minute — the GREEN
  module worked on its first real run, and the shim fallback path was
  avoided entirely.
- Reading both C headers up front (never from memory) made every attach
  signature correct on the first try.

**What could improve:**
- One test-authoring stumble: `T2->is($record->fail, undef, $name)` lost
  its test name because record accessors return an EMPTY LIST for NULL
  opaque fields in list context — the known T2 list-collapse trap in a new
  costume. Lexical assignment fixed it.

**Course corrections:**
- The alien-perl-bridge tarball install initially failed (cpanm build dir
  is outside the repo, so the `__FILE__` walk-up could not find the
  crate); re-ran with `ALIEN_TEMPORALIO_PERL_BRIDGE_EXT_PATH` set.

## Process Improvements

- Installing the Aliens from dzil-built tarballs (rather than leaning on
  PERL5LIB tricks) means the sdk/ test suite now exercises the real
  installed-Alien path that end users will hit — keep this as the standing
  dev-environment shape for P0.7+.

## Observations

- `temporal_core_runtime_new` accepts NULL telemetry and 0 heartbeat
  millis as defaults (verified in sdk-core-c-bridge runtime.rs: 0 maps to
  None, NULL telemetry takes the builder default).
- The eager attach loop doubles as the spec §4.1 version-skew tripwire:
  any symbol rename at a future pin bump will fail at `use` time with the
  C name, wrapper name, and both lib paths in the message.
- T-ffi-3 masks the Aliens via `$INC` stubs in a subprocess — it tests OUR
  diagnostic (the `-f` check naming the attempted path), not Platypus
  internals.

## Suggested Skills for Next Session

- No matching skill for the next step (P0.7 Temporalio::Core::ByteArray is
  pure-Perl + FFI::Platypus work; no Perl skill exists in the registry).
