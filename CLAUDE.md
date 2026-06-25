# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Temporal SDK for Perl, driving the Rust `sdk-core` through its C ABI
(`temporalio-sdk-core-c-bridge`) via `FFI::Platypus`. **Status: v0.1.0
complete** (Phases 0–5: client, worker, sync/async activities, workflows,
signals, queries, wait_condition, cancellation, continue-as-new, data
conversion). **v0.2 (feature parity with the mature SDKs, Phases 6–10) is in
progress** per spec §18–§31 and plan P6.1–P10.10.

## Document hierarchy (read in this order)

1. `spec.md` — the implementation contract. Every component has a public
   API, behavioral contract, failure modes, and test IDs (`T-*`). The
   prime directive (spec §0): Temporal-spec semantics first, Perl idioms
   second. When anything conflicts with spec.md, spec.md wins.
2. `plan.md` — TDD steps generated from the spec for `/bpe:execute-plan`
   (Phases 0–5 = v0.1, done; Phases 6–10 = v0.2, steps P6.1–P10.10). Each
   step is a prompt with RED/GREEN/REFACTOR sub-steps.
3. `todo.md` — per-sub-step checkbox tracker; check items off as completed.
4. `.ai-sessions/` — session summaries and `lessons.md`. Read the most
   recent summary before starting work; `lessons.md` holds hard-won
   toolchain gotchas (proto sub-message blessing, one-`class :isa`-per-file
   under Future::AsyncAwait on 5.38.2, `Future->call`-vs-`->wrap`, etc.).
5. `.v0.2-drafts/` (gitignored, scratch) — the fuller per-feature rationale,
   flagged-decision write-ups, and file:line reference anchors that were
   condensed into spec §18–§31. Consult the matching draft when a v0.2 spec
   section is terse.

## Commands

Deps (Test2::Suite, FFI::Platypus, IO::Async, Future::AsyncAwait,
Syntax::Keyword::Dynamically, the `Protobuf` dist, both Alien dists) live in
the `~/perl5` local::lib; `temporal` CLI is at `~/.local/bin`, `cargo` at
`~/.cargo/bin`, `dzil` at `~/perl5/bin`. The canonical invocations therefore
need those on `PERL5LIB`/`PATH`:

```bash
# full Perl test suite (unit/replay/integration)
( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lv t/unit/foo.t )   # one file
( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )            # author tests (POD)
( cd ext/temporalio-perl-bridge && cargo test )   # Rust shim tests
dzil test                       # per-distribution check (alien-core/, alien-perl-bridge/, sdk/)
```

- `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH=$HOME/Code/Temporal/sdk-rust` makes
  `Alien::Temporalio::Core` build from the local tree instead of fetching.
- Integration tests `skip_all` when the `temporal` dev server (or the env
  override) is unavailable — a green suite offline is expected.

### Build & memory guard (MANDATORY for any cargo / Alien / dzil build)

This host has **7.8 GiB RAM**; the kernel OOM killer has killed `rustc` (and
stray long-lived `claude` sessions) during release builds. An **8 GiB swapfile
was added 2026-06-25** (swappiness 60), which removes the hard OOM kills and
the memory-reclaim freezes that made the integration suite flaky (P10.0.7) —
but a build that thrashes into swap is slow, so the caps below still apply. For
EVERY cargo invocation — direct `cargo`, or indirect via `dzil test` / an
Alien rebuild:

- Set `CARGO_BUILD_JOBS=2` to cap peak memory. On a signal/OOM death, retry
  once with `CARGO_BUILD_JOBS=1` before declaring failure.
- Run builds in the **FOREGROUND** with a generous timeout (up to ~10 min).
  NEVER background a build — a backgrounded build is orphaned and dies when
  the process exits (this silently lost a build during the v0.1 run). If a
  foreground command times out, re-run it; cargo resumes incrementally.
- A full c-bridge / shim release build takes several minutes; that is normal.
  `sdk-rust/target/` is usually warm, so rebuilds are incremental.

### Shim-touching v0.2 steps (P9.2, P10.3, P10.4, P10.6)

A step that changes the Rust shim (`ext/temporalio-perl-bridge/src/lib.rs`) —
the log-forwarding 7th trampoline (P10.3), custom metric meters (P10.4),
custom slot suppliers (P10.6), the Nexus dispatcher (P9.2) — must, after the
edit: run `cargo test`, regenerate the cbindgen header, and **rebuild the
installed `Alien::Temporalio::PerlBridge`** so the SDK loads the new symbols
(the P0.10 precedent). All under the memory guard above.

## Architecture (big picture)

Three distributions in one monorepo, layered:

- `alien-core/` (`Alien::Temporalio::Core`) builds/ships
  `libtemporalio_sdk_core_c_bridge` from a pinned `sdk-rust` tag.
- `ext/temporalio-perl-bridge/` is OUR Rust shim, built by
  `alien-perl-bridge/`. It exists because sdk-core invokes completion
  callbacks on Tokio threads, which must NEVER touch the Perl
  interpreter. The shim's trampolines push results onto a per-runtime
  queue and signal an eventfd (pipe on non-Linux); Perl drains the queue
  from the IO::Async loop on the main thread. `user_data` passed to async
  bridge calls is a shim-allocated `{queue, callback_id}` pair, freed by
  the trampoline (single-shot).
- `sdk/` (`Temporalio-SDK`) is the Perl SDK. Async surface is
  `Future::AsyncAwait` over `IO::Async`. Workflows run in a custom
  deterministic scheduler (`Temporalio::Workflow::Runner`) that resolves
  `Temporalio::Workflow::Future`s manually from activation jobs — never
  via IO::Async timers. Sync activities run in an `IO::Async::Function`
  fork pool (children must close inherited FDs).

Protobuf is the pure-Perl `Protobuf` distribution
(github.com/MasonEgger/protobuf-perl): parser-direct over the complete
vendored proto trees in `sdk/share/proto/` — no `protoc`, no
`libprotobuf`. Message classes are generated at runtime under
`Temporalio::Proto::*`.

## Non-negotiable conventions

- Perl floor 5.38.0; `feature 'class'` everywhere with
  `no warnings 'experimental::class';` per file.
- Test files use Test2::V1 with the explicit preamble
  `use v5.38; use warnings; use utf8; use Test2::V1;` — V1 does NOT
  auto-enable strict/warnings/utf8.
- Dynamic scope across an `await` uses `Syntax::Keyword::Dynamically`,
  never `local` (Future::AsyncAwait panics — spec §16.1).
- Subroutine-attribute handlers obey the four constraints in spec §10.1
  (`:ATTR(CODE,BEGIN)`, handlers in the base class, base declared with
  `class`, `$data` is arrayref-or-undef). `sdk/t/spike/` holds the
  empirical proofs — don't delete them.
- FFI signatures target the C header at the pinned sdk-rust tag
  (`crates/sdk-core-c-bridge/include/temporal-sdk-core-c-bridge.h` in the
  sdk-rust checkout). Bumping the pin requires re-running the
  WorkerOptions echo test (plan P0.10).
- MUST-match constants (payload encodings, gRPC mappings, retry defaults)
  are verified against reference SDK source, not from memory — sibling
  checkouts live at `../sdk-python`, `../sdk-ruby`, `../sdk-rust`,
  `../sdk-typescript`.

## Reference repos

- C bridge header + protos source: `../sdk-rust/crates/`
- Workflow-semantics ground truth: `../sdk-python/temporalio/`
- Worker-architecture analog (closest design): `../sdk-ruby/temporalio/lib/`
- Protobuf dependency: `/home/mmegger/Code/MasonEgger/proto3-perl/`
