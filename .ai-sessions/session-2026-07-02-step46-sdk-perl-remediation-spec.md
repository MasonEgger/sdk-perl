# Session 2026-07-02: Step 46, sdk-perl Remediation Spec

## What Happened

Wrote the remediation spec (`spec.md` at the repo root, new file) from the step-45 verified findings, as stage P6 of the portfolio audit (`~/Code/spec.md`).
Input: `../../.ai-sessions/step-45-sdk-perl-verified.md` (68 confirmed defects, 1 refuted, 4 sub-claim refutations, 2 adjacent verifier discoveries).
Format follows the samples-perl remediation spec on that repo's portfolio-audit branch: Overview, Scope, Available Tooling, Global Requirements, numbered requirements with Defect / Root cause / Required behavior / Acceptance criteria / Test notes, Component Boundaries, Verification, Review Record.

## Shape of the Spec

70 requirements, ordered by severity: R1-R7 High, R8-R21 Medium-High, R22-R38 Medium, R39-R49 Low-Medium, R50-R70 Low.
The two adjacent findings became requirements: ADJ2 as R15 (Medium-High, next to its A1 sibling R14) and ADJ1 as R58 (Low, in the converter batch).
The memory-safety lifetime races (L1, L2, L3) lead the High band as a named cluster; the post-cancel corruption family (R4/R4b/R4c) is the R8-R10 cluster with the verify-45 probes cited as reproduce-first tests to be committed into `sdk/t/`.
Global Requirement 5 defines the acceptance convention for memory-safety items whose race a test cannot execute: guard existence plus a committed code-trace assertion.

## Contract Reconstruction

This repo has no root spec.md; the Overview reconstructs the intended contract from the archived v1 spec (`.ai-sessions/v1/spec.md`, prime directive §0), the live-hardening docs (`plan.md`, `todo.md`, `sdk-perl-issues-from-samples.md`, `ROOT-CAUSE-MAP.md`), and the shipped API surface mapped in the step-43 state note.
Bar: a Perl developer can build on this SDK against documented behavior.

## Review Record Highlights

Refuted candidate L27 recorded with no requirement.
Four sub-claim refutations recorded against R7, R22, R66, and R33.
The three samples-perl forwards are superseded by R22, R23, and R51; the samples-perl spec should cite those ids.

## Next

Stage P7: `/bpe:plan` this spec into a TDD roadmap on the portfolio-audit branch.
The verify-45 probe scratchpad is ephemeral; the R8-R10, R23, R28, and related reproduce-first tests must be committed early before the probe details go stale.
