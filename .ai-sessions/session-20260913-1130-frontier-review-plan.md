# Session Summary: Frontier Review Remediation Plan (F1-F15)

**Date**: 2026-09-13
**Duration**: orchestrator turn (plan authoring; no executor dispatch)
**Conversation Turns**: n/a (orchestrator-authored between two autonomous cycles)
**Estimated Cost**: n/a
**Model**: claude-fable-5-1 (orchestrator); reviews on claude-fable-5-1

## Goal Context

All fifteen issue-closeout steps (I1-I14, I18) had landed on `issue-closeout`, one commit each, with both suites green.
Mason asked for frontier-class eyes on every commit.
Fifteen independent read-only reviews ran in parallel on Fable 5.1, one per commit, with no edits, no commits, and no suite runs.
Four returned NEEDS FIX (I2, I3, I6, I18) and eleven SHIP WITH NITS.

## Key Actions

- Verified every block against the code before planning: the unblessed OTel header payload, the two-branch signal classification under cancel, the undrained dead poll loop, the TODO-wrapped canary, and the proto provenance.
- Wrote spec.md "Frontier Review Remediation (F1-F15)", plan.md "Section 6", and the matching todo.md checklist, blocks first.
- Recorded two orchestrator errors the reviews exposed: the v0.4.0 tag does hold the cloud, test, and health protos under crates/common/protos, and "TODO passed: 5" names test five rather than counting passes.

## Deviations from Plan

- This commit carries plan files only, made by the orchestrator so the executor's implement mode starts from a clean tree.
- The next cycle runs executors on Opus and the validator on Fable, per Mason's instruction, instead of the plugin's Sonnet and Opus defaults.

## Prompt Inventory

- Fifteen review dispatches, one per commit, each with the commit SHA, the spec and plan anchors, the Python ground-truth files with line ranges, and a fixed output contract (VERDICT, FINDINGS, PARITY, TESTS).

## Efficiency Insights

**What went well:**
- Read-only reviews are safe to run in parallel; fifteen finished in under six minutes of wall time.
- Asking each reviewer "what minimal change would make the tests pass with the bug intact" surfaced the weak assertion in nearly every step.

**What could improve:**
- The Opus validator passed thirteen em-dashes and every weak assertion the Fable pass caught; the validator brief should carry the same adversarial question.

**Course corrections:**
- None mid-turn.

## Process Improvements

- A finalize-stage red has no sanctioned path back into the fix loop in bpe 0.6.3; an orchestrator-synthesized findings block plus a mode=fix dispatch worked and should become a plugin path.

## Observations

- Two of the four blocks (I6 headers, I2 cancel regression) are user-visible behavior; two (I18, I12) are false claims in committed records that only a fix commit can correct, since commit bodies are immutable under the no-amend rule.

## Suggested Skills for Next Session

- None new.
