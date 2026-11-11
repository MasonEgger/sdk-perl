# Session Summary: Install protoc in CI for the sdk-core cargo build

**Date**: 2026-11-11
**Duration**: single orchestrator turn
**Conversation Turns**: n/a
**Estimated Cost**: n/a
**Model**: claude-fable-5-1

## Goal Context

With the alien installs made verbose (713e835), the build.log finally showed why the sdk-core cargo build dies on every hosted runner: `failed to run custom build command for prost-wkt-types v0.7.2`, "Could not find protoc".

## Key Actions

- Added `arduino/setup-protoc@v3` (with the repo token to avoid API rate limits) after the Rust install in both the matrix job and the Windows job, ahead of the Alien builds.
- Confirmed locally that the same cargo build succeeds on a host that has protoc (the alienfile `make` produced the cdylib in 3.2 seconds against the warm target).

## Deviations from Plan

- None; outside any plan step.

## Prompt Inventory

- None.

## Efficiency Insights

**What went well:**
- One verbose run exposed the whole remaining stack: the error, its crate, and its remedy.

**What could improve:**
- The alienfile could probe for protoc up front and die with the same rustup-style guidance it already gives for a missing cargo; a follow-up, not this commit.

**Course corrections:**
- None.

## Process Improvements

- Document protoc as a build prerequisite in the README's install section alongside cargo.

## Observations

- This is the fourth stacked break in the workflow (cpanm on dzil trees, authordeps at the wrong directory, retired macOS images, missing protoc), none of them in SDK code.

## Suggested Skills for Next Session

- None new.
