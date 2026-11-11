# Session Summary: First Full CI Suite Run and Its Five Failures

**Date**: 2026-11-11
**Duration**: single orchestrator turn
**Conversation Turns**: n/a
**Estimated Cost**: n/a
**Model**: claude-fable-5-1

## Goal Context

With Protobuf installed from git (82addfc) the SDK suite ran end to end on the Linux matrix for the first time: 213 files, 968 tests, with 2 to 6 failures per job depending on the Perl version.
None are SDK defects; three are test assumptions about the environment and two are dangling-pointer reads inside tests that perl 5.42.3's allocator exposed.

## Key Actions

- `t/unit/version.t` found the monorepo root at a fixed depth above the test file, which breaks under `dzil test` (runs from `sdk/.build/<id>/`). It now walks up to the nearest ancestor holding `alien-core/dist.ini` and `sdk/dist.ini`, and skips when there is none.
- `t/unit/attribute_handlers.t` constraint 1 matched the 5.38 diagnostic only; perl 5.40.5 and 5.42.3 try to `require` the plain-package base first and die with "Can't locate". The regex accepts both.
- `t/unit/activity_pool.t` T-act-10 required Linux::FD, a `recommends`; the subtest now skips without it, and the Linux CI jobs install Linux::FD so it still runs there.
- `t/unit/metric_meter.t` and `metric_meter_drop.t`: `baref` took a pointer into a signature parameter that dies on return; on 5.42.3 the freed PV was reused before the shim copied it ("requests\0requests" for "temporal_requests"). The helper pins each scalar for the file's lifetime.
- `t/integration/client_connect.t` decoded the api-key ByteArrayRef after `update_api_key` returned, past the method's `@keep` scope. The mock now decodes during the call, which is also the bridge's actual contract.
- Workflow: the tooling and SDK-deps cpanm runs retry up to three times (a macos-15 job lost its www.cpan.org downloads mid-run after about 100 installs), and Linux jobs add Linux::FD.

## Deviations from Plan

- None; outside any plan step.

## Prompt Inventory

- None.

## Efficiency Insights

**What went well:**
- Comparing the 5.38, 5.40, and 5.42 jobs separated the deterministic failures from the allocator-dependent ones in one pass.

**What could improve:**
- Both dangling reads would have been caught by any run under a different Perl; the matrix is doing the job it exists for.

**Course corrections:**
- None.

## Process Improvements

- Test helpers that hand pointers to the shim should follow the `@keep` pattern `craft_byte_array` already uses in `callback.t`; `baref` was the outlier.

## Observations

- Production `keep_buffer` and `Connection::update_api_key` were checked and hold their buffers for the call; the lifetime bugs were confined to tests.
- The Windows allow-failure job fails building Alien::Temporalio::PerlBridge; left for a later pass since it does not gate the workflow.

## Suggested Skills for Next Session

- None new.
