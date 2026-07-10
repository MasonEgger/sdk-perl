# Session Summary: Goal Step 12 — Vendor protos + Temporalio::Core::Proto (P0.11)

**Date**: 2026-06-12
**Duration**: ~20 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (~$1 — doc/source reads, one dzil build + cpanm install, short prove runs)
**Model**: claude-fable-5

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P0.11.1 RED through P0.11.5 Verify in one
  commit; **Phase 0 acceptance (spec §11) is fully green**
- **Subagent dispatches**: this summary covers dispatch 12
- **Steps completed**: 5 of 5 P0.11 sub-items (P0.11.1–P0.11.5)

## Key Actions

- Installed the `Protobuf` dependency (protobuf-perl 0.1.0) into ~/perl5
  from the local checkout: it is a pure dzil source tree (no Makefile.PL),
  so `dzil build` → `cpanm -l ~/perl5 <tarball>` (cpanm is at
  /usr/bin/cpanm, NOT ~/perl5/bin).
- Read the Protobuf dist's real API before coding (README, Generator.pm,
  Schema.pm, Parser.pm, the sdk_core_smoke.pl example): one shared
  `Protobuf::Parser`, merge subschemas into one `Protobuf::Schema` via
  `add_file` (dedupe by file name), `resolve`, then
  `Protobuf::Class::Generator->build` per message. The generator's
  full-name→package registry is PRIVATE, so Core::Proto keeps its own
  `%CLASS_FOR` for `resolve()`.
- Found that the installed Protobuf dist's WKT auto-include is a no-op
  (it resolves share/ relative to Parser.pm, but installs put it under
  auto/share/dist/Protobuf) — Core::Proto passes
  `File::ShareDir::dist_dir('Protobuf') . '/proto'` as an explicit
  include path; added `File::ShareDir` to sdk/cpanfile.
- P0.11.1: wrote `sdk/xt/author/vendor-protos.pl` (source from
  ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH; wipes share/proto then copies
  api_upstream/temporal/**, local/temporal/**, api_upstream/google/**
  EXCLUDING google/protobuf WKTs, .proto files only, plus LICENSE-api)
  and ran it: 66 files vendored from the local sdk-rust checkout
  (v0.4.0-24-g3839fa94; pin is v0.4.0 — same checkout prior steps built
  the header/Alien from).
- Discovered `workflow_activation_fq.proto` redefines every message of
  package `coresdk.workflow_activation` (a codegen aid; sdk-rust's
  build.rs compiles only core_interface.proto, which imports the non-fq
  file) — vendored but EXCLUDED from root parsing to avoid schema-index
  collisions.
- RED (P0.11.2): `sdk/t/unit/proto.t` with T-proto-1..5 (load idempotence;
  WorkflowActivation round-trip with WKT Timestamp + oneof job variants;
  StartWorkflowExecutionRequest with nested Payloads/map metadata;
  3-deep Failure cause chain; resolve() both trees + unknown-name death).
  All 5 subtests failed (module absent) — RED observed.
- Spiked the full-graph parse before GREEN: 712 messages / 63 files
  parse+resolve cleanly (including proto2 descriptor.proto via
  google/api/annotations.proto).
- GREEN (P0.11.3): `sdk/lib/Temporalio/Core/Proto.pm` — roots are every
  workflowservice/v1/*.proto + every non-fq coresdk file; mechanical
  package mapping (drop leading `temporal`, CamelCase components, prefix
  `Temporalio::Proto::`); depth-first class generation skipping map-entry
  messages; `resolve()` is a plain function that lazy-loads and throws
  Temporalio::Exception::Runtime on unknown names. Share-dir resolution:
  checkout-relative first, dist_dir('Temporalio-SDK') fallback.
- REFACTOR (P0.11.4): measured eager load at 1.706s — under the plan's
  2s lazy-build threshold, so eager generation stays (measured, not
  guessed). Second load: 6µs (idempotent guard).
- Verify (P0.11.5): `prove -lj4 t/unit/proto.t` PASS; full suite
  `PERL5LIB=~/perl5/lib/perl5 prove -lj4 t` → 9 files, 46 tests, exit 0,
  proto.t confirmed in prove's file list. Updated plan.md Current Status
  to **Phase 0: COMPLETE (P0.1–P0.11)**; checked off P0.11.1–P0.11.5.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P0.11 proto vendoring + Core::Proto), install Protobuf from local checkout, foreground builds | Installed Protobuf dist, read its API from source, wrote+ran vendor script (66 protos), RED proto.t, GREEN Core/Proto.pm, measured load time, full verify, plan/todo updates, summary, commit, push | Phase 0 acceptance green; suite 46 tests, exit 0 |

## Efficiency Insights

**What went well:**
- Reading the dependency's source (Generator.pm in full, the sdk-core
  smoke example) before writing any code meant the GREEN implementation
  passed on its first run — the example encoded the exact
  multi-root/one-schema merge pattern Core::Proto needed.
- The 30-second standalone parse spike between RED and GREEN de-risked
  the only real unknown (proto2 descriptor.proto in the graph) without
  burning a test-debug cycle.

**What could improve:**
- `rm -rf` of the dzil tarball ran unconditionally after a failed cpanm
  call (wrong cpanm path), forcing a rebuild — verify the install
  succeeded before deleting the artifact it came from.

**Course corrections:**
- cpanm assumed at ~/perl5/bin per the dispatch hints; actual location
  /usr/bin/cpanm — one retry.

## Process Improvements

- When the sdk-rust pin is bumped: re-run `xt/author/vendor-protos.pl`,
  then `prove -lj4 t/unit/proto.t` (T-proto-1 catches parse breaks with
  the offending file path; T-proto-3 guards the deepest import chain).

## Observations

- The vendored trees merge into one `share/proto/temporal/` root:
  api_upstream's `temporal/api/**` and local's `temporal/sdk/core/**`
  coexist; google/api/{annotations,http}.proto are the only non-WKT
  google deps.
- Protobuf's installed share dir lands at
  `~/perl5/lib/perl5/auto/share/dist/Protobuf/proto` — locatable only
  via File::ShareDir, not via the parser's checkout-relative fallback.
- Leftover handoff `.ai-sessions/handoffs/handoff-20260610-1145-autonomous-run.md`
  kept (active autonomous-run context; autonomous mode defaults to keep).

## Suggested Skills for Next Session

- No matching skill for the next step (P1.1 Temporalio::Cancellation is a
  small synchronous Perl token class; no Perl skill exists in the
  registry).
