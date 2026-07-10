# Session Summary: Goal Step 14 — Core::Callback issue_async + drain (P1.2)

**Date**: 2026-06-12
**Duration**: ~15 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (<$1 — ground-truth reads, layout probe, four prove runs)
**Model**: claude-fable-5

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P1.2.1 RED through P1.2.4 Verify in one
  commit; async completion dispatch is now live end to end
- **Subagent dispatches**: this summary covers dispatch 14
- **Steps completed**: 4 of 4 P1.2 sub-items (P1.2.1–P1.2.4)

## Key Actions

- Verified ground truth before writing anything: the shim header/source
  (`ext/temporalio-perl-bridge/{include/temporalio-perl-bridge.h,src/lib.rs}`)
  for the entry struct, drain semantics (clears the eventfd itself; pipe
  read-end is Perl's job), and trampoline shapes; and sdk-rust's
  `temporal_core_byte_array_free`, which returns immediately on
  `disable_free` — proving Perl-crafted test ByteArrays survive the drain
  loop's free path. No shim changes were needed (no cargo rebuild).
- Probed FFI::Platypus::Record's layout of the entry struct empirically
  before trusting it: `record_layout_1` inserts the same interior padding
  as C (kind at 8 + 7 pad, rpc_status_code at 40 + 4 pad, 64-byte stride).
- RED (P1.2.1): `sdk/t/unit/callback.t` — T-cb-1 (pending Future resolves
  with poll bytes via the real trampoline called by address through
  `$ffi->function($ptr, ...)`), bridge-failure path, null/null shutdown
  sentinel → done(undef), T-cb-2 (1000 concurrent), T-cb-3 (stale id warns,
  drops, frees both BAs — asserted via a `byte_array_free` spy), T-cb-4
  (cap=256 per drain call, loops until 0 — via a `queue_drain` spy),
  unknown-kind Exception::Argument. All awaits guarded by
  `Future->wait_any($f, $loop->timeout_future(after => 15))` so a broken
  drain can never hang the suite. Observed RED (7/7 fail).
- GREEN (P1.2.2): added the `Temporalio::Core::FFI::CallbackEntry` record
  (TemporalioPerlBridgeEntry mirror); built out
  `sdk/lib/Temporalio/Core/Callback.pm` — process-wide monotonic id,
  per-instance pending hash, cached trampoline pointers keyed by kind name
  (worker_poll/worker/connect/rpc/server_start/server_shutdown),
  `issue_async` class method per spec §4.5, drain loop (pipe read-end
  cleared before popping; buffer of 256 entry slots; cast per-slot record
  views), per-kind completion dispatch, ByteArray freeing after
  consumption, stale-id warn-and-drop. Wired `Temporalio::Runtime`'s fd
  watcher to the real drain (weakened `$self` so the watcher closure
  doesn't break the DESTROY-warning contract) and added a `callback`
  accessor.
- REFACTOR (P1.2.3): the per-kind builders were written as the
  `%COMPLETE_FOR_KIND` dispatch table keyed on entry.kind from the start;
  reviewed, no further restructuring needed.
- Verify (P1.2.4): `prove -lj4 t/unit/callback.t` PASS (7 subtests); full
  suite `PERL5LIB=~/perl5/lib/perl5 prove -lj4 t` → 11 files, 56 tests,
  exit 0. Checked off P1.2.1–P1.2.4 in todo.md; plan.md Current Status
  updated (next: P1.3 ephemeral dev server).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P1.2 Core::Callback full implementation), header/source-verified shapes, foreground builds | Ground-truth reads, record layout probe, RED callback.t, GREEN Callback.pm + CallbackEntry record + Runtime watcher wiring, verify, plan/todo updates, summary, commit, push | Suite 11 files / 56 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The 30-second layout probe (write sentinel fields, hexdump the record)
  settled the record-padding question definitively before any test code
  depended on it.
- Reading sdk-rust's `byte_array_free` source first confirmed the plan's
  `disable_free=1` test strategy is safe (early return, no Box::from_raw
  on Perl-owned memory) instead of discovering a heap corruption later.

**What could improve:**
- First GREEN run failed because helper subs defined before the `class`
  block compiled into package `main`, so calls from inside the class
  didn't resolve. One rewrite cycle to move helpers inside the block.

**Course corrections:**
- Moved `_consume_byte_array`/`_bridge_failure`/`%COMPLETE_FOR_KIND`
  inside the class block after the package-main resolution failure.

## Process Improvements

- When a module is a bare `class` file (no `package` statement), define
  every helper sub INSIDE the `class { }` block — file-scope subs land in
  `main::` and are invisible to code compiled inside the class.

## Observations

- Spec §4.5 says a worker_poll fail_ba resolves the Future "done with a
  Temporalio::Exception::Bridge" but the worker kind says "fail with";
  implemented both as `->fail` (consistent, lets `await` throw) — the
  "done" wording is almost certainly a typo.
- RPC completions (kind 4) resolve `done` with a
  `{success,status_code,failure_message,failure_details}` hashref; the
  §7.5 gRPC-code → exception mapping is deferred to the client layer
  (P1.5/P1.8 own the exception classes and table).
- The Runtime's watcher closure must hold only a weakened `$self`:
  loop → handle → closure → self is a cycle that would silently disable
  the DESTROY warning runtime.t asserts.
- Leftover handoff `.ai-sessions/handoffs/handoff-20260610-1145-autonomous-run.md`
  kept (active autonomous-run context; autonomous mode defaults to keep).

## Suggested Skills for Next Session

- No matching skill for the next step (P1.3 ephemeral dev server is Perl
  FFI/IO::Async + Net::EmptyPort work; no Perl skill exists in the
  registry).
