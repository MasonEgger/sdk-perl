# Session Summary: Goal Step 45 — GitHub Actions CI workflow (P5.4)

**Date**: 2026-06-13
**Duration**: ~20 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (~$1.5 — additive infra: one workflow YAML, no
production code change, two full local test suites for verification)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P5.4.1 and P5.4.2 in one commit.
- **Subagent dispatches**: this summary covers dispatch 45
- **Steps completed**: 2 of 2 P5.4 sub-items (P5.4.1, P5.4.2)

## Key Actions

- **P5.4.1 — wrote `.github/workflows/ci.yml`** at the REPO ROOT (monorepo
  with three dists). Authored directly from spec §14 (this is infra, not TDD;
  the verifiable check is "valid YAML referencing runnable commands" plus a
  locally-green suite). The workflow has two jobs:
  - `test`: the blocking primary matrix. `fail-fast: false`,
    `os: [ubuntu-22.04, ubuntu-24.04, macos-14, macos-13]` ×
    `perl: ["5.38", "5.40", "5.42"]` = 12 jobs, exactly the spec §14 matrix.
    Steps mirror the spec §14 stage list and what works locally:
    1. checkout sdk-perl;
    2. checkout `temporalio/sdk-rust@v0.4.0` into `sdk-rust/` (the pin matches
       `alien-core/alienfile` `$pinned_tag`), exposed to the Core Alien via
       `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH` so no tarball fetch/digest dance
       runs in CI;
    3. `shogo82148/actions-setup-perl` (spec §14 stage 1);
    4. `dtolnay/rust-toolchain@stable` (stage 2);
    5. cargo cache (`~/.cargo/registry`, `~/.cargo/git`, both `target/` dirs)
       and cpanm cache (`~/.cpanm`) per spec §14 "Cache";
    6. install Dist::Zilla + AlienBuild plugin + authordeps (stage 3);
    7. build+install `Alien::Temporalio::Core` (`dzil install` so it lands in
       PERL5LIB for the SDK suite — cargo-builds the c-bridge in place from the
       pinned checkout) (stage 4);
    8. build+install `Alien::Temporalio::PerlBridge` (in-tree shim; alienfile
       walks up to `ext/`) (stage 5);
    9. install SDK deps `--with-develop` (Protobuf is a git dep per cpanfile);
    10. install the `temporal` CLI via `temporalio/setup-temporal` so the
        integration stage RUNS (rather than skip_all) — spec §14 stage 8 says
        run integration against an ephemeral dev server, and §14 is otherwise
        silent on the CLI so I followed the dispatch hint "prefer installing
        the temporal CLI";
    11. `dzil test --all` on `sdk/` (stages 6 + 8 — full unit/replay/integration
        suite; `dzil test` is the spec §14 stage-6 command);
    12. `prove -lj4 xt` author tests (stage 7 — POD syntax + coverage).
  - `windows`: the spec §14 allow-failure portability canary
    (`windows-2022`, strawberry-perl 5.40, `continue-on-error: true`,
    `x86_64-pc-windows-msvc` Rust target). Same build chain, NO temporal CLI
    install — integration tests `skip_all`, an accepted green-offline outcome
    per CLAUDE.md.
  - Added `concurrency` (cancel-in-progress per ref) and `env`
    (`SDK_RUST_TAG: v0.4.0`, `CARGO_BUILD_JOBS: "2"` to honor the 7.8 GiB
    memory guard, `CARGO_TERM_COLOR`).
  - Triggers: `push: branches: ["**"]`, `pull_request`, `workflow_dispatch` —
    so the feature-branch push from this very commit triggers the run.

- **P5.4.2 — verification.** In-dispatch verification per the dispatch's
  explicit VERIFICATION SCOPE:
  1. YAML validity: `python3 -c 'yaml.safe_load(...)'` → parses; confirmed
     `jobs == [test, windows]` and the matrix is the 4-OS × 3-Perl spec set.
  2. Local full suite `cd sdk && prove -lj4 t` (with the temporal CLI on PATH)
     → exit 0, 253 tests across 44 files, integration LIVE.
  3. Author tests `cd sdk && prove -lj4 xt` → exit 0, 188 tests (pod-syntax +
     pod-coverage).

## CAVEAT (read before re-entry)

P5.4.2 "green on feature branch" is checked off on the basis of a **valid
workflow + locally-green suite**. A live GitHub Actions run cannot be observed
from inside a subagent dispatch — the actual matrix run is triggered by THIS
commit's push (`push: branches: ["**"]`) and must be confirmed on GitHub by
the orchestrator/user. If the remote run is red, the likely first-run friction
points are: (a) `temporalio/setup-temporal@v0` action version/availability;
(b) `shogo82148/actions-setup-perl` building 5.38/5.40/5.42 on the older
runners; (c) the `dzil install --install-command "cpanm ... ."` pattern for
the Alien dists on macOS/Windows; (d) sdk-core cargo build time/memory on the
hosted runners. None of these can be exercised locally.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P5.4 — CI workflow per spec §14) | Read latest session summary + spec §14 + plan P5.4; inspected both alienfiles, cpanfile, dist.ini names, integration skip logic, sdk-rust pin; wrote `.github/workflows/ci.yml` (12-job matrix + allow-failure Windows); validated YAML; ran full `t` suite (live integration) + `xt`; checked off P5.4.1/P5.4.2; summary; commit; push | YAML valid; `t` 253 ok exit 0; `xt` 188 ok exit 0 |

## Efficiency Insights

**What went well:**
- Treating CI as additive infra (author from spec §14 + the proven local build
  chain) rather than forcing a RED/GREEN test was correct — the verifiable
  condition is YAML validity + locally-green suite, which the dispatch spelled
  out. No wasted cycles inventing a test for a YAML file.
- Mirroring the exact local build path (`ALIEN_..._SDK_RUST_PATH` override +
  `dzil install` so the Aliens land in PERL5LIB before the SDK suite runs)
  means the CI steps match a known-working sequence.

**What could improve:**
- The pinned sdk-rust tag lives in two places now (`alien-core/alienfile`
  `$pinned_tag` and the workflow `env.SDK_RUST_TAG`). A future pin bump (plan
  P0.10 territory) must touch both. Documented inline in the workflow.

## Observations

- Local `git describe` on `../sdk-rust` reads `v0.4.0-24-g3839fa94` — the
  checkout is a few commits past the tag, but the Alien builds from whatever
  tree the override points at; CI pins exactly `v0.4.0`, which is the contract.
- The full `t` suite runs integration LIVE here because the `temporal` CLI is
  at `~/.local/bin/temporal`; the integration tests `skip_all` cleanly without
  it (verified design, CLAUDE.md "green suite offline is expected").

## Suggested Skills for Next Session

- None required for P5.5 (v0.1.0 release prep): RED version-agreement test
  (`sdk/t/unit/version.t` asserting `$Temporalio::SDK::VERSION`, the three
  `dist.ini` versions, and `Alien::Temporalio::Core->version` agree), GREEN set
  versions, update spec §11 + plan Current Status, final `prove -lj4 t xt` +
  `cargo test` sweep. Standard TDD on a small Perl module — ground truth is the
  three `dist.ini` files and the pinned sdk-core version.
