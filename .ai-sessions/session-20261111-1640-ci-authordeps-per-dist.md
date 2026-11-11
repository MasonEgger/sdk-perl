# Session Summary: Install dzil author plugins per distribution in CI

**Date**: 2026-11-11
**Duration**: single orchestrator turn
**Conversation Turns**: n/a
**Estimated Cost**: n/a
**Model**: claude-fable-5-1

## Goal Context

The first run after the workflow fix (0b9ba4b) got past dependency installation and died at `dzil listdeps --missing` in alien-core with "Required plugin bundle Dist::Zilla::PluginBundle::Starter::Git isn't installed."

## Key Actions

- Traced it to the tooling step: `dzil authordeps --missing` ran at the repository root, which has no dist.ini, so it listed nothing and the trailing `|| true` hid the miss.
- Rewrote both tooling steps to run authordeps inside each of alien-core, alien-perl-bridge, and sdk under `shell: bash`, with the empty-list guard and without `|| true`.
- Confirmed locally that `dzil authordeps` in each directory lists the Starter::Git bundle and the AlienBuild plugin.

## Deviations from Plan

- None; outside any plan step.

## Prompt Inventory

- None.

## Efficiency Insights

**What went well:**
- The job log named the missing bundle and the exact remedy.

**What could improve:**
- A `|| true` on a dependency install is how this hid for four months.

**Course corrections:**
- None.

## Process Improvements

- Never swallow a dependency install's exit code in CI.

## Observations

- The macOS 15 and 26 runners picked up jobs, so the matrix change is good.

## Suggested Skills for Next Session

- None new.
