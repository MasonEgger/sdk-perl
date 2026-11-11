# Session Summary: Install the Protobuf Distribution From Git in CI

**Date**: 2026-11-11
**Duration**: single orchestrator turn
**Conversation Turns**: n/a
**Estimated Cost**: n/a
**Model**: claude-fable-5-1

## Goal Context

With protoc installed (9ebb85c) both Alien dists build on the hosted runners, and the failure moved to the SDK suite: every test dies with "Can't locate Protobuf/Parser.pm".
The job log shows cpanm "Successfully installed Protobuf-0.09", which is an unrelated CPAN distribution.
cpanm ignores the cpanfile's `git =>` key, so the SDK's Protobuf (github.com/MasonEgger/protobuf-perl, version 0.1.0, a dzil source tree) never reached the runner.

## Key Actions

- Added an "Install Protobuf (git)" step to both jobs ahead of "Install SDK deps": shallow clone into RUNNER_TEMP, `dzil authordeps` and `listdeps --missing` through cpanm, `dzil install`, then a load check of Protobuf::Parser that prints the version.
- Dropped the workflow comment claiming Protobuf is installed as a git dependency through the cpanfile.

## Deviations from Plan

- None; outside any plan step.

## Prompt Inventory

- None.

## Efficiency Insights

**What went well:**
- The log line naming Protobuf-0.09 pinned the cause in one read.

**What could improve:**
- A `requires 'Protobuf', '0.1.0'` floor in sdk/cpanfile would make cpanm reject the CPAN 0.09 instead of silently accepting it; a follow-up outside this CI fix.

**Course corrections:**
- None.

## Process Improvements

- The README install section should say the Protobuf dist is installed from git with dzil, matching what CI now does.

## Observations

- Fifth stacked CI break; still none in SDK code.

## Suggested Skills for Next Session

- None new.
