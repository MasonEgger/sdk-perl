# Session Summary: B0 triage — ROOT-CAUSE-MAP.md

**Date**: 2026-06-26
**Duration**: single autonomous step (B0.1-B0.3)
**Conversation Turns**: n/a (subagent dispatch)
**Estimated Cost**: low
**Model**: claude-opus-4-8[1m]

## Key Actions

- Completed B0 (B0.1, B0.2, B0.3): read-only triage of all eleven live-SDK bugs
  in sdk-perl-issues-from-samples.md and wrote ROOT-CAUSE-MAP.md at the repo root.
  Doc-only: no test or source file changed, suite stays green.
- Verified every cited code anchor in the current v1 tree before recording it:
  - #3/#4: Runner.pm:1372 `@conditions = @still` clobbers a condition the
    synchronous continuation re-registers at 1360-1366. Confirmed shared root.
  - #6/#7: terminal-command emission has no per-activation de-dup
    (Runner.pm:2697-2698 `cancel_workflow_execution()` plus `_apply_cancel_workflow`
    2050-2142 and the loser-cancel sweep ~1447-1458). Shared path confirmed.
  - #5/#8: native `$main_run_future->cancel` at Runner.pm:2138-2139 (and the
    update-await result path near 2667) does not raise a throwable
    Temporalio::Exception::Cancelled. Shared cancel-routing family.
  - #1/#2: Callback.pm:257-271 creates the eventfd (259) and pipe (264-269)
    without FD_CLOEXEC/O_CLOEXEC. The shim only borrows the fd at lib.rs:1675.
  - #9: Worker.pm:422 `enable_local_activities => 0` hardcoded.
  - #11: Worker.pm:424 `enable_nexus => 0` hardcoded.
  - #10: Worker.pm:246-253 build_activity_inbound/build_workflow_inbound defined
    with zero dispatcher callers (only method defs, POD 989-998, an OTel comment).
- Recorded a plan-anchor correction: B4.2 points the FD fix at the shim
  (lib.rs ~1670), but the shim only borrows the fd. The CLOEXEC fix is Perl-side
  in Callback.pm:257-271. Logged in the map.

## Observations

- Confirmed four shared-root clusters (#3/#4, #6/#7, #5/#8, #1/#2), so B1, B2,
  B3, B4 each close two bugs with one fix. #9, #10, #11 are standalone.
- B5.2 still needs to confirm whether the local-activity SEGV (#9) originates at
  the Perl-side `enable_local_activities => 0` config or in the shim resolution
  path; the map flags this as a B5.2 diagnosis item.
- Full suite green before commit: Files=86, Tests=522, Result: PASS.

## Suggested Skills for Next Session

- bpe:execute-plan or bpe:goal for B1.1 (first RED+GREEN fix step, C-COND).
