# Accomplishment: R1-R97 Remediation and Reference-SDK Parity

**Archived**: 2026-09-11
**Convergence**: converged (313 of 313 todo items checked)

## Spec Slice

The archived `spec.md` in this directory is the full remediation and feature-parity contract: 97 requirements against the v0.2.0 tree.
R1-R70 are the step-45 adversarially-verified defects (memory safety, cancellation semantics, wire format, test infrastructure, POD drift) plus two adjacent finds (ADJ1, ADJ2).
R71-R97 are the reference-SDK feature-parity gaps from the 2026-07-06 audit against `../sdk-python`.
The bar: feature-complete parity with the reference SDKs so a Perl developer can build against documented behavior and reach for any capability the reference SDKs expose.

## What Got Done

- All 97 requirements (R1-R97) landed as TDD steps, one green commit each, across 10 phases (P1 memory safety, P2 pool fork-channel, P3 wire format/codec, P4 post-cancel cluster, P5 cancellation semantics, P6 workflow/client semantics, and the parity phases through R97).
- Reproduce-first discipline held: every defect shipped a failing test that ships as permanent coverage; parity items assert the missing capability against the cited Python source.
- Suites green at 859 tests / 197 files including live integration against a dev server, plus 462 author (POD) tests.
- The distribution was made installable (#19) and the README brought up to date with the remediation (#17, #20).
- CLAUDE.md marked the remediation complete (#16).

## Deferred or Dropped

The 15 known follow-ups discovered during the run were filed as GitHub issues rather than folded into this cycle, and are the input to the next plan:

- #1 async :Update parked on wait_condition croaks on evict (handler-future sibling of R8-R10)
- #2 die in a sync :Signal handler silently swallowed (Python fails the task)
- #3 fatal poll-loop death never unwinds Worker::run
- #4 Schedule Action _from_proto drops user_metadata and most optional fields
- #5 Test::Worker shutdown() reports success when the drain wedges
- #6 OTel workflow-outbound spans not wired onto the R71 interceptor chain
- #7 fork-pool activities: heartbeat interceptor bypassed, cancellation_details unavailable in children
- #8 start_update should accept result_type
- #9 dynamic update handler validator accepted but ignored
- #10 Priority.priority_key not validated at construction
- #11 WorkflowHandle fetch_history convenience method missing
- #12 cloud/test/health raw service handles not exposed
- #13 count_workflows POD documents the wrong return shape
- #14 unused POSIX import and duplicated Duration conversion (cleanup)
- #18 two attribute-bearing classes per file fail to compile (upstream perl/F::AA parser bug; worked around, kept as a canary)

## Notable Decisions

- Each follow-up was scoped out of its discovering step deliberately (documented in the matching `.ai-sessions/session-*.md` observations) so steps stayed atomic; the fixes were filed as issues to keep the R1-R97 cycle green and bounded.
- #18 is an upstream perl 5.38+/Future::AsyncAwait parser-state bug, not an SDK defect; the SDK routes around it (one attributed class per file) and the issue exists as a tracker plus future xfail canary.

## Files Touched

- `spec.md`, `plan.md`, `todo.md` (this archive)
- `sdk/lib/Temporalio/**` (the SDK surface: Worker, Runner, Client, Activity pool, Schedule, Converter, Interceptor, Contrib/OpenTelemetry, Common)
- `ext/temporalio-perl-bridge/src/lib.rs` (shim steps: log forwarding, metric meters, slot suppliers, Nexus dispatcher)
- `sdk/t/{unit,replay,integration}/**`, `sdk/xt/**` (repro-first coverage)
- `README.md`, `CLAUDE.md`

## Lessons Cross-Reference

- `.ai-sessions/lessons.md`: proto sub-message blessing, one-`class :isa`-per-file under Future::AsyncAwait on 5.38.2 (the root of #18), `Future->call`-vs-`->wrap`, the R8-R10 post-cancel cluster mechanism (parent of #1), and the poll-drain parity note (parent of #3).
- Per-step session summaries `.ai-sessions/session-2026070*-goal-step-*.md` carry the observation notes that seeded issues #1-#14.
