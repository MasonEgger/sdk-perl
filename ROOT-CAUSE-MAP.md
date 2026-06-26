# Root-cause map (B0 triage)

Read-only triage of the eleven bugs in `sdk-perl-issues-from-samples.md`. Every
file:line anchor below was opened and confirmed during this pass against the
current `v1` tree. No test or source file changed; this is the map that the
B1-B7 fix steps consume.

Severity tags carry over from the issues doc. The "Perl vs shim" column says
which layer the fix lands in, which decides whether a step has to run the Rust
build ritual (cargo test, cbindgen regen, Alien rebuild) under the memory guard.

## Map

| Bug | Cluster (plan step) | Planned repro test | Suspected root (file:line) | Layer | Test type |
|-----|---------------------|--------------------|----------------------------|-------|-----------|
| #3 wait_condition re-park dropped at CAN boundary | B1 C-COND | `t/unit/repro_check_conditions.t` | `sdk/lib/Temporalio/Workflow/Runner.pm:1372` (`@conditions = @still` clobbers a condition the synchronous continuation re-registered at 1360-1366) | Perl | replay |
| #4 wait_condition timer re-arm wedge | B1 C-COND | same file, timer re-arm variant | same as #3 (Runner.pm:1372) | Perl | replay |
| #6 try_cancel activity emits duplicate CancelWorkflowExecution | B2 C-CANCEL-CMD | `t/unit/repro_cancel_commands.t` | terminal-command emission has no "at most one per activation" guard: `Runner.pm:2697-2698` pushes `cancel_workflow_execution()` with no de-dup against the cancel chain in `_apply_cancel_workflow` (Runner.pm:2050-2142) | Perl | replay |
| #7 wait_any race emits cancel + double-complete, SEGV | B2 C-CANCEL-CMD | `t/unit/repro_wait_any_race.t` | same terminal/loser-cancel path as #6 (Runner.pm:2697-2698 plus the `$f->cancel` loser sweep around 1447-1458) | Perl | replay (assert command list, not in-process) |
| #5 never-true wait_condition does not throw Cancelled | B3 C-CANCEL-LIVE | `t/integration/repro_cancel_live.t` | `Runner.pm:2138-2139` `$main_run_future->cancel` is a native Future cancel that surfaces a raw "was cancelled" string instead of a throwable `Temporalio::Exception::Cancelled` | Perl | subprocess-guarded integration |
| #8 client cancel mid-`:Update` does not surface clean WorkflowFailure | B3 C-CANCEL-LIVE | `t/integration/repro_cancel_mid_update.t` (~30s guard; hangs ~183s today) | same cancel-routing family as #5: update-await result path around `Runner.pm:2667` plus the native cancel at 2139; the await raises a raw cancelled Future | Perl | subprocess-guarded integration |
| #1 sync fork-pool worker + ephemeral dev server SEGVs at `$server->shutdown` | B4 C-FD | `t/integration/repro_fd_signal.t` | NOT a CLOEXEC/signal-fd bug (the original Callback.pm:257-271 anchor was DISPROVEN by experiment). REAL CAUSE (verified live): the sync-activity `IO::Async::Function` fork pool makes IO::Async install a process-wide SIGCHLD reaper (`Loop::watch_process` -> `_reap_children`'s `waitpid(-1)`) that LINGERS past worker shutdown. At `$server->shutdown` that reaper reaps sdk-core's ephemeral `temporal` CLI subprocess before sdk-core's own `waitpid`, and core SEGVs (exit 139). Production is unaffected: a worker against an external server never runs the ephemeral-server shutdown. FIX is test-teardown-side in `sdk/lib/Temporalio/Test/DevServer.pm` (`shutdown` suspends the lingering reaper for the core-shutdown window). NO shim change. | Perl (test infra) | subprocess-guarded integration |
| #2 cross-workflow signal hand-off stalls after first grant | B4 C-FD | `t/integration/repro_external_signal.t` | ALREADY HEALTHY on current v1 (verified: A signals B twice via `get_external_workflow_handle`, both delivered). NOT the same root as #1. The repro is kept as a regression guard. | Perl (no fix needed) | subprocess-guarded integration |
| #9 live execute_local_activity segfaults (exit 139) | B5 C-LOCALACT | `t/integration/repro_local_activity.t` | `sdk/lib/Temporalio/Worker.pm:422` `enable_local_activities => 0` is hardcoded, so the core worker never enables the local-activity path the SDK then drives; B5.2 must confirm whether the SEGV origin is this Perl-side config or the shim resolution path | Perl (confirm in B5.2; shim if diagnosis points there) | subprocess-guarded integration |
| #10 worker inbound interceptor chains never invoked | B7 C-ICEPT | `t/unit/worker_inbound_interceptor.t` + `t/integration/repro_interceptor_inbound.t` | `sdk/lib/Temporalio/Worker.pm:246-253` `build_activity_inbound` / `build_workflow_inbound` are defined but have zero dispatcher callers (only the method defs, POD at 989-998, and an OTel interceptor comment reference them) | Perl | unit spy + subprocess-guarded integration |
| #11 worker hardcodes enable_nexus => 0 | B6 C-NEXUS | `t/integration/repro_nexus.t` | `sdk/lib/Temporalio/Worker.pm:424` `enable_nexus => 0` is hardcoded and no Nexus task poll loop is wired | Perl (shim rebuild only if the poller needs new symbols) | subprocess-guarded integration |

## Shared roots (flagged)

- **#3 and #4 share one root:** the `@conditions = @still` rebuild at
  Runner.pm:1372 drops any condition the synchronous continuation re-registers
  during the same `_check_conditions` pass. One fix (merge re-registered
  conditions instead of overwriting) closes both. B1.

- **#6 and #7 share the terminal-command de-dup path:** both emit an extra
  terminal/cancel command because nothing guards "at most one workflow-terminal
  command per activation" at the `@commands` emission sites (Runner.pm:2697-2698
  and the `_apply_cancel_workflow` chain). Centralizing that guard (B2.3) fixes
  both.

- **#5 and #8 share the cancel-routing family:** neither path raises a throwable
  `Temporalio::Exception::Cancelled`; both bottom out in the native
  `$main_run_future->cancel` at Runner.pm:2139 (and, for #8, the update-await
  result path near 2667). The B3 fix routes every internal await's cancel
  through the throwable-Cancelled Future subclass, covering both.

- **#1 and #2 do NOT share a root (correction).** The B0 triage guessed both
  were one signal-fd-CLOEXEC bug; the B4 investigation DISPROVED that. #1 is a
  child-reaper ownership race (IO::Async's lingering process-wide SIGCHLD reaper
  vs. sdk-core's ephemeral-server `waitpid`), fixed test-teardown-side in
  `Temporalio::Test::DevServer->shutdown`; no shim/Callback.pm change. #2 was
  already healthy on current v1 and only needs a regression guard. B4.

## Plan-anchor correction recorded during triage

The plan's B4.2 line points the FD fix at the shim ("lib.rs ~1670"). Triage
confirmed the shim only borrows the fd (`temporalio_perl_bridge_queue_new` takes
`signal_fd: i32` at lib.rs:1675); it never creates or owns it.

**Superseded by the B4 implementation (recorded here).** The signal-fd/CLOEXEC
hypothesis (whether shim-side OR Perl-side in Callback.pm) was DISPROVEN by
experiment. #1 has nothing to do with closing the bridge signal fd. The verified
mechanism is a child-process REAPER race: the sync-activity `IO::Async::Function`
fork pool makes IO::Async install a process-wide SIGCHLD reaper that does
`waitpid(-1)` and lingers past worker shutdown; at `$server->shutdown` it reaps
sdk-core's ephemeral `temporal` CLI subprocess out from under core's own
`waitpid`, SEGVing core. The `[SHIM]` label on Step B4 is therefore wrong: NO
shim, NO Callback.pm, and NO cargo/Alien rebuild are involved. The fix lives in
`Temporalio::Test::DevServer->shutdown`, which detaches the lingering reaper for
the core-shutdown window so core reaps its own child (and reaps any still-watched
fork-pool worker itself to avoid a zombie). #2 was already healthy.

## Out of scope for this map

The activity-choice "unknown order hangs" item (issues doc, "Actionable fix"
section) is a sample defect in `samples-perl`, not an sdk-perl bug. It is tracked
as B8.1 and touches no file in this repo.
