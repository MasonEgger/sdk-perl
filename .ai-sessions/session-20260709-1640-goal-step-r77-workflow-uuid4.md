# Session Summary: Step R77, Add workflow.uuid4 Deterministic UUID

**Date**: 2026-07-09
**Duration**: ~15 minutes
**Conversation Turns**: 1 (autonomous dispatch)
**Estimated Cost**: low (single step-executor dispatch)
**Model**: claude-fable-5

## Goal Context

- **Condition**: execute todo.md step R77 (workflow.uuid4 deterministic UUID, parity in-workflow finding 1), one commit
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (R77.1 through R77.4 checked; full suite green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1

## Key Actions

- Verified the Python mechanism first: `workflow/_context.py:866` builds `uuid.UUID(bytes=random().getrandbits(16 * 8).to_bytes(16, "big"), version=4)`, i.e. 128 bits from the SAME seeded RNG that `random()` returns, with `uuid.UUID(version=4)` forcing the version nibble to 4 and the variant bits to RFC 4122 10xx.
- RED: `sdk/t/replay/workflow_uuid4.t` plus the `WfDef::UuidCaller` fixture (two `uuid4()` calls per run), four subtests: canonical v4 shape (version nibble 4, variant 8/9/a/b), second call differs from the first, replay stability (same seed twice reproduces both values), and seed derivation (seed 42 vs 99 differ).
Pre-fix failure confirmed honest via `push_activation_completion`: "Undefined subroutine &Temporalio::Workflow::uuid4".
- GREEN: `Temporalio::Workflow::uuid4` in Workflow.pm next to `random` (:72): four `irand` draws off `_runner()->random` (the ISAAC generator) packed `N4` big-endian, the Python bit-stream equivalent; version/variant bits stamped; canonical lowercase string returned, matching the `Client::_new_uuid` string convention.
- REFACTOR: already structurally satisfied (draws from the shared RNG, so `UpdateRandomSeed` re-seeds it for free); the comment cites in-workflow finding 1, `_context.py:866`, and notes the T-det-4 guard self-exemption holds because no builtin is touched. `=head2 uuid4` POD added before `wait_condition`.
- Verify: `prove -lj4 t` green (174 files, 786 tests, live integration included); `prove -lj4 xt` green (422).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: R77, workflow.uuid4 | RED replay test + fixture, RNG-backed uuid4 with v4 bit-stamping, POD | Step complete, suites green, one commit |

## Efficiency Insights

**What went well:**
- The T-wf-10 test in `runner_basics.t` was a ready-made template for seed-driven replay assertions; cloning its `run_with_seed` shape made RED a single pass.
- Checking the RED failure reason through `push_activation_completion` (not just the empty command list) confirmed the test fails for the documented cause before writing any implementation.

**What could improve:**
- Nothing notable; no test-harness stumbles this step.

**Course corrections:**
- None.

## Process Improvements

- When a replay test needs the workflow's failure cause, `push_activation_completion` exposes the failed completion directly; `push_activation` returns an empty list for failed completions and hides the reason.

## Observations

- Cross-SDK bit parity of the UUID bytes is impossible (ISAAC vs Mersenne Twister) and not the contract; the contract is deterministic-per-seed with v4 shape, which both SDKs honor.
- `uuid4` inherits `UpdateRandomSeed` re-seeding for free because it draws from the runner's single `$rng` rather than caching a generator.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R78 (timer/sleep/wait_condition user-metadata summaries) works against `workflow/_context.py:878,894` and the StartTimer command metadata.
