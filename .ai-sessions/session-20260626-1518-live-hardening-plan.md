# Session Summary: Archive v1 docs and add the live-hardening plan

**Date**: 2026-06-26
**Duration**: planning pass for the bug-fix phase
**Conversation Turns**: n/a (continuation)
**Estimated Cost**: low
**Model**: claude-opus-4-8[1m]

## Key Actions

- Archived the v1 implementation docs: spec.md, plan.md, and todo.md (the v0.1 +
  v0.2 build contract) moved to .ai-sessions/v1/ now that v1 is complete.
- Added a new live-hardening plan (plan.md + todo.md) for the bug-fix phase,
  generated via /bpe:plan from sdk-perl-issues-from-samples.md (already committed)
  as the spec. The plan fixes the 11 live-SDK defects the samples build surfaced,
  organized into 6 root-cause clusters (C-COND, C-CANCEL-CMD, C-CANCEL-LIVE, C-FD,
  C-LOCALACT, C-NEXUS, C-ICEPT) plus a triage doc step (B0) and a cleanup step (B8).
- Made the plan autonomous-safe for /bpe:goal: B0 is doc-only (ROOT-CAUSE-MAP.md,
  no failing tests), each fix step carries its repro AND its fix in one green
  commit (reproduce-first inside the step), and crash/hang repros (#1,#3,#6,#7,#8,
  #9,#11) run in a timeout-guarded subprocess so RED is a clean assertion, never a
  harness crash. This respects the per-commit green-gate.

## Observations

- The earlier "reproduce all first" B0 was incompatible with the autonomous
  green-gate (it committed failing tests) and risked crashing the harness on the
  SEGV/hang repros. Folding RED into each fix step fixes both.

## Suggested Skills for Next Session

- bpe:execute-plan or bpe:goal for the B-steps.
