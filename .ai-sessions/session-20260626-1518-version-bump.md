# Session Summary: Bump to v0.2.0 and refresh status docs

**Date**: 2026-06-26
**Duration**: part of the post-v0.2 doc-consistency pass
**Conversation Turns**: n/a (continuation)
**Estimated Cost**: low
**Model**: claude-opus-4-8[1m]

## Key Actions

- Bumped all three distributions and the shim crate to 0.2.0: the three dist.ini,
  ext/temporalio-perl-bridge/Cargo.toml, and every hardcoded `our $VERSION`
  (SDK.pm, EnvConfig.pm, Core/FFI.pm, Core/FFI/WorkerOptions.pm,
  SlotSupplierRegistry.pm, alien Core.pm, PerlBridge.pm), plus the version
  agreement test (version.t $AGREED_VERSION + labels). version.t passes; the
  sdk-core pin (0.4.0) stays an independent axis.
- Refreshed status docs to v0.2: CLAUDE.md status line ("v0.2.0, feature-complete;
  unit and replay suites green") and doc-hierarchy paths (now point at
  .ai-sessions/v1/ where the implementation docs were archived); README.md status
  block and "Not yet supported" section (time-skipping test env, Windows, CPAN).

## Observations

- Phrased the status honestly as "implemented; unit and replay green" rather than
  "verified live", since live-server defects from the samples build are tracked
  separately and the live-hardening phase has not run yet.

## Suggested Skills for Next Session

- None.
