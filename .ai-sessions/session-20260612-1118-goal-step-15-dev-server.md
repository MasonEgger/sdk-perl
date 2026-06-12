# Session Summary: Goal Step 15 — Ephemeral dev server (P1.3)

**Date**: 2026-06-12
**Duration**: ~15 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (<$1 — ground-truth reads, gcc layout probe, five prove runs)
**Model**: claude-fable-5

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P1.3.1 RED through P1.3.3 Verify in one
  commit; the SDK can now boot and tear down a real Temporal dev server
  in-process
- **Subagent dispatches**: this summary covers dispatch 15
- **Steps completed**: 3 of 3 P1.3 sub-items (P1.3.1–P1.3.3)

## Key Actions

- Ground truth first: read the pinned header's ephemeral-server section
  and sdk-rust's `crates/sdk-core-c-bridge/src/testing.rs` in full. Key
  findings baked into the implementation: (a) `existing_path` set →
  `EphemeralExe::ExistingPath`, otherwise CachedDownload where an EMPTY
  `download_version` becomes `Fixed("")` — so the Perl default must be
  the literal string `'default'`; (b) the spawned CLI inherits
  stdout/stderr (`Stdio::inherit`); (c) the shutdown async block borrows
  the server box, so `ephemeral_server_free` may only run after the
  shutdown callback fires; (d) the bridge runtime must outlive the server.
- Verified both new record layouts empirically BEFORE writing SDK code:
  a gcc `offsetof`/`sizeof` probe against the real header
  (TestServerOptions 112 bytes: port@80, extra_args@88, ttl@104;
  DevServerOptions 96 bytes: ui@56, ui_port@58, log_format@64) matched a
  sentinel-value hexdump of the planned `record_layout_1` declarations
  exactly.
- Installed `Net::EmptyPort` (Test-TCP dist) into ~/perl5 — plan P1.3
  requires it for free-port-per-file; it was missing from the local::lib
  (already declared in sdk/cpanfile test requires, so no cpanfile change).
- RED (P1.3.1): `sdk/t/integration/dev_server.t` — gate: `TEMPORAL_CLI`
  env override, else PATH scan for `temporal`, `skip_all` when absent
  (offline CI stays green; no download is ever attempted in tests); the
  FFI-heavy modules are `require`d after the gate. Tests: start returns
  host:port target; two servers in one process get distinct ports;
  shutdown idempotent. Observed RED (compile failure, module missing).
- GREEN (P1.3.2): added `TestServerOptions`/`DevServerOptions` records +
  `ephemeral_server_start_dev_server`/`_shutdown`/`_free` attaches to
  `Core::FFI`; created `sdk/lib/Temporalio/Test/DevServer.pm` — blocking
  `start` over the P1.2 callback bridge (`server_start` kind), random
  port via `Net::EmptyPort::empty_port`, STDERR dup'd to
  `t/tmp/dev-server.<pid>.log` around the spawn window (child inherits
  fd 2 for life; TAP stays clean), timeout-guarded awaits (start 60s,
  shutdown 30s) so a wedged bridge can never hang the suite, idempotent
  `shutdown` that frees the C handle only after the callback, unknown
  start options raise Exception::Argument, DESTROY warns (cannot run the
  loop from a destructor).
- Verify (P1.3.3): dev_server.t PASS against the real CLI (two server
  boots, ~1s); skip path verified with a stripped PATH (`Result:
  NOTESTS`); no leftover server processes (`pgrep`); full suite
  `prove -lj4 t` → 12 files, 59 tests, exit 0. todo.md P1.3.1–3 checked;
  plan.md Current Status updated (next: P1.4 payload converters).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P1.3 ephemeral dev server), header/testing.rs-verified shapes, foreground builds, CLI at ~/.local/bin/temporal | Ground-truth reads, gcc + Record layout probes, Net::EmptyPort install, RED dev_server.t, GREEN FFI records/attaches + Test/DevServer.pm, verify (run + skip paths), plan/todo updates, summary, commit, push | Suite 12 files / 59 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The paired gcc-offsetof + Perl sentinel-hexdump probe settled both
  record layouts in one shot; the integration test then passed on its
  very first GREEN run — zero debug cycles against a real server.
- Reading `testing.rs` (not just the header) surfaced the
  free-after-callback ordering constraint and the `download_version`
  empty-string trap before either could become a use-after-free or a
  confusing download failure.

**What could improve:**
- Nothing notable; the step was linear.

**Course corrections:**
- None.

## Process Improvements

- For every new by-value record, keep using the two-sided probe (gcc
  offsetof on the real header vs sentinel hexdump of the Record class)
  before any test depends on the layout — it has now twice eliminated
  layout-debugging entirely (P1.2 entry struct, P1.3 options structs).

## Observations

- The dev server's gate is the `temporal` CLI binary: `TEMPORAL_CLI` env
  override first, then PATH. The suite genuinely exercises the server
  when the CLI is present and skip_alls otherwise — `prove` runs that
  don't have `~/.local/bin` on PATH will skip the integration file.
- sdk-core's `start_server()` polls until the server is serving, so
  `DevServer->start` returning implies a connectable target.
- The CLI at `log_level => 'warn'` writes nothing to the stderr log; the
  log file exists for failure debugging, lives in gitignored `sdk/t/tmp/`.
- Spec §12.2's "Random namespace prefix per test" concerns the Phase-1
  client tests (namespace isolation), not DevServer itself — namespace
  defaults to 'default'; callers override per test.
- Leftover handoff `.ai-sessions/handoffs/handoff-20260610-1145-autonomous-run.md`
  kept (active autonomous-run context; autonomous mode defaults to keep).

## Suggested Skills for Next Session

- No matching skill for the next step (P1.4 payload converters is pure
  Perl + vendored proto classes; no Perl skill exists in the registry).
