# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Temporal SDK for Perl, driving the Rust `sdk-core` through its C ABI
(`temporalio-sdk-core-c-bridge`) via `FFI::Platypus`. **Pre-implementation
phase**: the contract and roadmap exist; Phase 0 code does not yet.

## Document hierarchy (read in this order)

1. `spec.md` — the implementation contract. Every component has a public
   API, behavioral contract, failure modes, and test IDs (`T-*`). The
   prime directive (spec §0): Temporal-spec semantics first, Perl idioms
   second. When anything conflicts with spec.md, spec.md wins.
2. `plan.md` — 34 TDD steps (P0.1–P5.5) generated from the spec for
   `/bpe:execute-plan`. Each step is a prompt with RED/GREEN/REFACTOR
   sub-steps.
3. `todo.md` — per-sub-step checkbox tracker; check items off as completed.
4. `.ai-sessions/` — session summaries and `lessons.md`. Read the most
   recent summary before starting work.

## Commands

```bash
cd sdk && prove -lj4 t          # full Perl test suite (unit/replay/integration)
cd sdk && prove -lv t/unit/foo.t  # one test file
cd sdk && prove -lj4 xt         # author tests (POD coverage etc.)
cd ext/temporalio-perl-bridge && cargo test   # Rust shim tests
dzil test                       # per-distribution check (alien-core/, alien-perl-bridge/, sdk/)
```

- `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH=<sdk-rust checkout>` makes
  `Alien::Temporalio::Core` build from a local tree instead of fetching.
- Integration tests `skip_all` when the dev server or the env override is
  unavailable — a green suite offline is expected.

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
