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
| #9 live execute_local_activity segfaults (exit 139) | B5 C-LOCALACT | `t/integration/repro_local_activity.t` | CONFIRMED Perl-side, NO shim. Root: `sdk/lib/Temporalio/Worker.pm` hardcoded `enable_local_activities => 0`, so core never stood up the local-activity manager the SDK drives; every `ScheduleLocalActivity` command was dropped. On CURRENT HEAD (post-B4) the SEGV is GONE — the B4 teardown-reaper fix removed the exit-139 crash family, so the symptom is now a clean HANG (the LA never resolves, the workflow waits forever). Fix (B5.3): set `enable_local_activities => (@$workflows && @$activities) ? 1 : 0` (sdk-ruby worker.rb rule); LA tasks then arrive through the existing `poll_activity_task` path and the existing dispatcher runs them. Boundary guard (B5.4): thread `local_activities_enabled` Worker -> WorkflowDispatcher -> Runner; `schedule_local_activity` dies cleanly when off, so a regression (workflow calls execute_local_activity on a no-activities worker) is a workflow-task error, not a hang/SEGV. | Perl (no shim) | subprocess-guarded integration |
| #10 worker inbound interceptor chains never invoked | B7 C-ICEPT | `t/unit/worker_inbound_interceptor.t` + `t/integration/repro_interceptor_inbound.t` | `sdk/lib/Temporalio/Worker.pm:246-253` `build_activity_inbound` / `build_workflow_inbound` are defined but have zero dispatcher callers (only the method defs, POD at 989-998, and an OTel interceptor comment reference them) | Perl | unit spy + subprocess-guarded integration |
| #11 worker hardcodes enable_nexus => 0 | B6 C-NEXUS | `t/integration/repro_nexus.t` | CONFIRMED Perl-side, NO shim. Root: `sdk/lib/Temporalio/Worker.pm` hardcoded `enable_nexus => 0` AND no Nexus task poll loop wired. UNLIKE #9 (local activities, which rode the existing `poll_activity_task` path with only a flag flip), Nexus needed THREE Perl-side additions: (a) FFI bindings for `worker_poll_nexus_task` / `worker_complete_nexus_task` (both already exported by the pinned core C bridge — `nm -D` on the installed `libtemporalio_sdk_core_c_bridge.so` confirms `temporal_core_worker_poll_nexus_task` + `temporal_core_worker_complete_nexus_task`; same `TemporalCoreWorkerPollCallback`/`TemporalCoreWorkerCallback` types as the activity pair, so the existing trampoline pointers serve them — NO shim/cargo/Alien rebuild); (b) a dedicated Nexus poll loop in `run()` (the existing `NexusDispatcher`, already complete with full start/cancel/error routing, just had zero callers); (c) `enable_nexus` gated on registered Nexus services. Fix (B6.2/B6.3): `enable_nexus => $self->_nexus_enabled` (true iff `$nexus_registry->services` is non-empty), `_poll_nexus_task`/`_complete_nexus_task` over the callback bridge, `_build_nexus_dispatcher`, and a `Temporalio::Worker::PollLoop` wired in `run()` only when `_nexus_enabled` (core rejects `worker_poll_nexus_task` when the flag is off, so a non-Nexus worker must not start it). Live round trip resolves in ~4s (was a 45s+ hang). | Perl (no shim) | subprocess-guarded integration |

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

## Residual findings (B8.2 safety valve, recorded 2026-06-26)

The B8.2 sample-revert pass un-gated the workarounds one at a time and ran each
live smoke. Eight passed clean (#2, #3, #5, #6, #7, #8, #9). Four did NOT: the
B1-B7 fixes covered a related-but-different symptom, leaving a residual SDK bug.
These become fix steps B9, B10, B11.

| Bug | Residual cluster (plan step) | What B1-B7 fixed vs. what remains | Suspected root (file:line) | Layer | Test type |
|-----|------------------------------|-----------------------------------|----------------------------|-------|-----------|
| #1 sync fork-pool child corrupts the bridge signal fd | B9 C-FD-REAL | B4 fixed a DIFFERENT symptom: the `Temporalio::Test::DevServer` teardown-reaper SEGV (IO::Async's lingering SIGCHLD reaper stealing core's ephemeral-server child at `$server->shutdown`). The PRODUCTION bug remains: the real sync-activity sample wedges live with "signal fd 13 write failed (Bad file descriptor)" + a ~200s hang. The sync-activity `IO::Async::Function` fork-pool CHILD closes the bridge completion-queue signal fd in its inherited-FD hygiene sweep, so the parent's trampoline write fails. (CLOEXEC was disproven in B4's ISOLATED minimal repro, but the real sample pattern still corrupts the fd.) | fd creation in `sdk/lib/Temporalio/Core/Callback.pm` (set close-on-exec on the eventfd/pipe) AND/OR the Worker/Activity fork-pool child FD-close sweep (exclude the bridge signal fd) | Perl | subprocess-guarded integration |
| #4 wait_condition WITH A TIMEOUT still wedges | B10 C-COND-TIMEOUT | B1's plain re-park fix (covers #3) is present, but the durable-timer-backed timeout path is distinct: arm a long timer, an `:Update` moves the deadline, re-arm a short timer against the moved deadline — the stale timer is not cleanly cancelled before the new one arms and the workflow hangs. | the timeout-timer cancel/re-arm path in `sdk/lib/Temporalio/Workflow/Runner.pm` | Perl | replay (preferred) or subprocess-guarded integration |
| #10 workflow-inbound input missing start headers | B11 C-ICEPT-HEADERS | B7 wired the workflow-inbound chain so the hook is now invoked, but the runner builds the inbound `ExecuteWorkflow` input WITHOUT the start headers (Runner.pm ~1685-1690 passes only `type`/`args`/`_root`). The now-invoked inbound hook has no header to read, so context propagation forwards an EMPTY header and the downstream activity reads `request_id=(none)`. The InitializeWorkflow job carries the headers; they are not threaded into the inbound input. | the inbound-input build in `sdk/lib/Temporalio/Workflow/Runner.pm` (~1685-1690) | Perl | unit (inbound-input build) or integration (context propagation) |
| #11 nexus re-verify after #1 | B9 (shares #1's fd path) | B6 enabled Nexus serving + wired the poll loop and the round-trip resolved in B6's repro, but #11's sample rides the same sync fork-pool fd path as #1, so it must be RE-VERIFIED live after B9 fixes the signal fd. | shares #1's root (Callback.pm / fork-pool FD sweep) | Perl | subprocess-guarded integration (re-verify) |

**Correction to the #1/#2 note above.** The earlier "Shared roots" entry and the
"Superseded by the B4 implementation" note record that B4 fixed #1. That is only
half true and is corrected here: B4 fixed the test-teardown reaper-race SEGV, NOT
#1's production signal-fd corruption. The production bug is the fork-pool child
closing the bridge completion-queue signal fd, fixed in B9 (Callback.pm
close-on-exec and/or the fork-pool FD-sweep exclusion). B4's DevServer teardown
fix stands; it simply did not cover the production path.

## Out of scope for this map

The activity-choice "unknown order hangs" item (issues doc, "Actionable fix"
section) is a sample defect in `samples-perl`, not an sdk-perl bug. It is tracked
as B8.1 and touches no file in this repo.
