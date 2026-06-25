# Session Summary: core->Perl log forwarding (P10.3, spec section 28.1)

**Date**: 2026-06-24
**Duration**: ~55 minutes
**Conversation Turns**: 1 (autonomous bpe:step-executor dispatch)
**Estimated Cost**: ~$4-5 (Opus, shim cargo builds + two Alien reinstalls + full -lj4 suite + xt)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: Implement P10.3 (the kind-7 / 7th shim trampoline that forwards
  sdk-core's structured logs to a duck-typed Perl logger); cargo test green,
  full `prove -lj4 t` exit 0, pushed to origin/v1.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: 1
- **Subagent dispatches**: 1 (this one)
- **Steps completed**: 1 of 1 (P10.3.1/.2/.3 checked off)

## Key Actions

- Shim (ext/temporalio-perl-bridge/src/lib.rs): added kind-7
  (`TEMPORALIO_PERL_BRIDGE_KIND_FORWARDED_LOG`), three shim-owned log buffers +
  a timestamp + a level (in `rpc_status_code`) on `TemporalioPerlBridgeEntry`,
  a process-global registry (`FORWARDING_QUEUE`/`FORWARDING_ACCESSORS`/
  `FORWARDING_ACTIVE`), the `forwarded_log` trampoline (deep-copies target/
  message/fields-JSON via the accessors into NUL-terminated CStrings), a `Drop`
  on the entry that frees undrained kind-7 buffers, and
  `temporalio_perl_bridge_forwarded_log_free` for drained entries.
- KEY DECISION (corrected mid-run): the shim must NOT declare core's
  `temporal_core_forwarded_log_*` accessors as undefined `extern "C"`. The first
  attempt did, and the installed cdylib failed to load —
  `undefined symbol: temporal_core_forwarded_log_target` — because FFI::Platypus
  loads each `.so` RTLD_LOCAL, so the shim's undefined symbols never resolve
  against the separately loaded core lib. Fix: Perl resolves the four accessors
  itself (`$ffi->find_symbol`) and passes their function pointers to
  `forwarding_register(queue, target, message, timestamp_millis, fields_json)`;
  the trampoline calls through the stored pointers. Zero hard link to core.
- cargo test: added 5 log-forwarding tests (deep-copy survives immediate free =
  T-logfwd-3; shutdown frees N undrained = T-logfwd-5; level rides in status
  code; single-owner registry; null-registry drop). Test binary supplies its own
  `#[no_mangle]` accessor defs. 17/17 cargo tests green.
- Regenerated the cbindgen header (build.rs) and rebuilt the installed
  `Alien::Temporalio::PerlBridge` twice (dzil build -> cpanm --reinstall with
  `ALIEN_TEMPORALIO_PERL_BRIDGE_EXT_PATH`), once per shim ABI change; verified
  symbols via `nm -D` and confirmed NO undefined `temporal_core_forwarded`
  symbols in the final cdylib. All cargo/Alien builds CARGO_BUILD_JOBS=2,
  foreground.
- Perl SDK: new `Temporalio::Runtime::LogForwardingConfig` (duck-typed logger,
  four assembly flags, `_on_log` mirroring sdk-python `_on_logs`, throwing-logger
  isolation, `is_enabled` gate, process-global `$ACTIVE`); `LoggingConfig` gains
  `forward_to` (sets the kind-7 trampoline pointer in `to_ffi`);
  `Core::FFI::CallbackEntry` record extended to the new 96-byte layout +
  `forwarded_log_accessor_ptrs`/attaches; `Callback.pm` kind-7 drain builder
  (short-circuits before the pending lookup, frees the shim buffers, calls
  `_on_log`); `Runtime.pm` claims/releases the registry + Perl-side "second
  forwarder -> Argument" pre-check.
- sdk/t/unit/log_forwarding.t: T-logfwd-1/2/4/6/7 + logger-validation, 6 subtests.
- Verified: cargo 17/17; full `prove -lj4 t` 435 tests exit 0; `prove -lj4 xt`
  (POD) green after documenting `LogForwardingConfig->active`.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute P10.3 (kind-7 log forwarding), shim-touching, memory guard, fold into one commit | shim kind-7 + registry + deep-copy/free/Drop, header regen, 2x Alien reinstall, LogForwardingConfig + LoggingConfig forward_to + Callback drain + Runtime wiring, RED/GREEN both layers | cargo 17/17, suite 435 green |

## Efficiency Insights

**What went well:**
- The RTLD_LOCAL undefined-symbol failure surfaced immediately on the first
  Perl test run (not silently), and the find_symbol+pass-pointers redesign was a
  clean, self-contained fix that also made the cargo test independent of core.

**What could improve:**
- The first shim design hard-linked core's accessors; reading lessons.md or the
  existing FFI load pattern (each lib attached on its own handle) up front would
  have flagged RTLD_LOCAL before the wasted first Alien reinstall.

**Course corrections:**
- Replaced the `extern "C"` accessor block with an accessor-pointer table passed
  from Perl after the cdylib refused to load.

## Process Improvements

- For any shim function that must call a CORE symbol: pass the core function
  pointer from Perl (resolved via `$ffi->find_symbol`), never declare it as an
  undefined extern in the shim. FFI::Platypus loads libs RTLD_LOCAL.

## Observations

- The new Entry layout is 96 bytes (was 64); the `CallbackEntry` record and the
  C struct must stay in lockstep or the drain stride corrupts every slot.
- kind-7 deliberately bypasses `$pending`/`callback_id` (no Future); the drain
  must dispatch it before the pending lookup.

## Suggested Skills for Next Session

- None required. Next step is P10.4 (custom metric meters), the other half of
  spec section 28 and also shim-touching (8-callback meter set, aggregate in
  Rust, main-thread-marshal create/free); temporal-developer may help only if
  metric semantics come up. The RTLD_LOCAL lesson above applies directly to
  P10.4's meter callbacks.
