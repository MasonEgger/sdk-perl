# Session Summary: Fix the CI workflow so a run can complete

**Date**: 2026-11-11
**Duration**: single orchestrator turn (diagnosis plus one workflow edit; no executor dispatch)
**Conversation Turns**: n/a
**Estimated Cost**: n/a
**Model**: claude-fable-5-1

## Goal Context

Mason asked why CI was failing on PR #30 and then asked for it to be fixed.
CI had never been green on this repository; every run on main back to July was failure or cancelled, and the branch had not touched the workflow, the cpanfile, or either Alien distribution.

## Key Actions

- Read the September failure's job log through the Actions API: every blocking job died at "Install Perl tooling" because cpanm could not fetch Alien-Build-2.87, a release since withdrawn from CPAN (2.88 shipped on 2026-09-19).
- Dispatched a fresh run on the branch; the tooling step passed everywhere and every Linux job then died at "Build Alien::Temporalio::Core" within two minutes, the same step as July.
- Reproduced that locally: `cpanm --showdeps .` in alien-core reports "Configuring ... N/A" because a Dist::Zilla source tree has no Makefile.PL, Build.PL, or cpanfile, so `cpanm --installdeps .` has nothing to configure.
- Found both macOS legs of the matrix dead: macos-14 jobs cancel within a second ("The configuration 'macos-14-arm64-us-default' is not supported") and macos-13 jobs queue forever; the runner-images list carries macos-15 and macos-26.
- Edited .github/workflows/ci.yml: the four Alien dependency steps now run `dzil listdeps --missing` piped to cpanm under `shell: bash`, the matrix uses macos-15 and macos-26, and the tooling step pins Alien::Build@2.88.
- Verified `dzil listdeps` in both Alien directories and the cpanm pin syntax locally; validated the YAML; cancelled the diagnostic run.

## Deviations from Plan

- None; this was outside any plan step.

## Prompt Inventory

- None (no subagents).

## Efficiency Insights

**What went well:**
- The Actions API returned the job log where `gh run view --log` returned nothing, and the local `cpanm --showdeps .` reproduction made the root cause certain without a CI round trip.

**What could improve:**
- Two background watchers were killed by the harness memory monitor on a box with 8 GB available; the Monitor tool with a bounded poll loop worked.

**Course corrections:**
- None.

## Process Improvements

- The first green run will be the first time the cargo build of the core and the shim is exercised on hosted runners; watch that step next.

## Observations

- The Windows allow-failure job shared the same `cpanm --installdeps .` mistake and gets the same fix.

## Suggested Skills for Next Session

- None new.
