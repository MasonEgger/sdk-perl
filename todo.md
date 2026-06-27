# sdk-perl live-hardening TODO

Bug-fix phase tracker. Spec: `sdk-perl-issues-from-samples.md`. Plan: `plan.md`.
Each fix step is one green commit carrying its repro AND its fix (B0 is the map
only); shim steps fold in the cargo/cbindgen/Alien rebuild. Reproduce-first:
every fix's RED must fail for the documented reason before GREEN. Crash/hang
repros run in a timeout-guarded subprocess (never in-process); every commit
leaves the suite green.

## B0 Triage doc (ROOT-CAUSE-MAP.md)
- [x] B0.1 Investigate each cluster read-only; locate the suspected root file:line (no test/source changes)
- [x] B0.2 Write ROOT-CAUSE-MAP.md: bug# -> cluster -> planned repro -> root file:line -> Perl/shim -> test type (replay vs subprocess-guarded integration); flag same-root candidates
- [x] B0.3 Verify suite stays green (doc-only); commit ROOT-CAUSE-MAP.md + session summary

## B1 C-COND: preserve continuation-registered conditions (#3, #4)
- [x] B1.1 RED: create repro_check_conditions.t (replay; CAN-boundary synchronous re-park) + #4 timer re-arm variant; fails for the documented reason first
- [x] B1.2 GREEN: _check_conditions merges conditions registered during the pass instead of `@conditions = @still`
- [x] B1.3 REFACTOR: re-entrancy-safe condition-list mutation; comment cites #3
- [x] B1.4 Verify: both replay repros pass; full `prove -lj4 t` green

## B2 C-CANCEL-CMD: valid, de-duplicated cancel commands (#6, #7)
- [x] B2.1 RED: create repro_cancel_commands.t (single CancelWorkflowExecution) + repro_wait_any_race.t (replay asserts emitted command list, not in-process: no double-complete / no cancel of resolved seq); fail first
- [x] B2.2 GREEN: emit at most one workflow-terminal command per activation; no RequestCancel for an already-resolved wait_any loser
- [x] B2.3 REFACTOR: centralize terminal-command guarding; comment cites #6/#7
- [x] B2.4 Verify: both replay repros pass; full `prove -lj4 t` green; existing cancellation replays still pass

## B3 C-CANCEL-LIVE: throwable Cancelled + clean cancel-mid-update (#5, #8)
- [x] B3.1 RED: create repro_cancel_live.t (never-true wait_condition -> Cancelled) + repro_cancel_mid_update.t (SUBPROCESS-GUARDED ~30s; mid-:Update hangs ~183s today); fail first
- [x] B3.2 GREEN: wait_condition + update-await (Runner.pm ~2667) raise Temporalio::Exception::Cancelled via the Future-subclass pattern
- [x] B3.3 REFACTOR: every internal await (timer/activity/condition/update/child) routes cancel through throwable-Cancelled; comment cites #5/#8
- [x] B3.4 Verify: both live repros pass un-gated; re-run B1+B2 repros; full `prove -lj4 t` green

## B4 C-FD: fork-pool/dev-server child-reaper ownership at teardown (#1; #2 regression guard)
- [x] B4.1 RED: create repro_fd_signal.t (sync fork-pool activity + ephemeral dev server, full lifecycle incl. $server->shutdown) + repro_external_signal.t (two cross-workflow signals delivered); SUBPROCESS-GUARDED; repro_fd_signal.t fails first with signal 11 (SEGV) at $server->shutdown; #2 already healthy (regression guard)
- [x] B4.2 GREEN: Temporalio::Test::DevServer->shutdown suspends IO::Async's lingering process-wide SIGCHLD reaper for the core-shutdown window so sdk-core reaps its own ephemeral-server CLI child (test-teardown-side; NO shim/cargo change)
- [x] B4.3 GREEN: reap any still-watched (stopped) fork-pool worker in the suspend helper to avoid a zombie after detaching the reaper
- [x] B4.4 REFACTOR: document the reaper-ownership contract in DevServer.pm (helper cites #1) + cross-reference comment at the fork pool in Activity/Pool.pm
- [x] B4.5 Verify: repro_fd_signal.t passes un-gated; repro_external_signal.t passes; full `prove -lj4 t` green

## B5 C-LOCALACT: fix execute_local_activity segfault (#9)
- [x] B5.1 RED: create repro_local_activity.t (plain local activity returns, no exit 139) + a timeout+retry variant; SUBPROCESS-GUARDED (SEGV exit 139); fail first
- [x] B5.2 Diagnose: locate the segfault origin (Perl-side resolution vs shim path); record in ROOT-CAUSE-MAP.md + flag shim-touching or not
- [x] B5.3 GREEN: minimal fix at the identified layer (memory guard + Alien rebuild if shim)
- [x] B5.4 REFACTOR: boundary guard so a regression is a clean error, not a SEGV
- [x] B5.5 Verify: live repro passes; eager-workflow-start local-activity path works live; full `prove -lj4 t` green

## B6 C-NEXUS: enable Nexus serving + wire the task poller (#11)
- [x] B6.1 RED: create repro_nexus.t (one-worker caller->handler round-trip resolves); SUBPROCESS-GUARDED (blocks forever today); fail first
- [x] B6.2 GREEN: set enable_nexus from registered Nexus services (not hardcoded 0) and wire the Nexus task poll loop (memory guard + Alien rebuild if shim)
- [x] B6.3 REFACTOR: gate enable_nexus on actual Nexus registration; comment cites #11
- [x] B6.4 Verify: live round-trip passes; non-Nexus integration tests unaffected; full `prove -lj4 t` green

## B7 C-ICEPT: invoke worker inbound interceptor chains (#10)
- [x] B7.1 RED: worker_inbound_interceptor.t spy asserts inbound execute_activity/execute_workflow (+ signal/query/update) invoked in order; repro_interceptor_inbound.t live smoke
- [x] B7.2 GREEN: wire built inbound chains into the activity dispatcher + workflow activation dispatch
- [x] B7.3 REFACTOR: ordering matches the outbound contract (client then worker, outermost first); comment cites #10
- [x] B7.4 Verify: unit spy + live smoke pass; full `prove -lj4 t` green

## B8 Cleanup: sample fix, revert workarounds, docs live-verified
- [x] B8.1 activity-choice sample fix (samples-perl): Menu returns undef; Workflow raises non-retryable Application; update t/01 + confirm t/02-smoke fast (committed samples-perl @3b3dded)
- [~] B8.2 PARTIAL: revert sample workarounds per the cleanup contract. 8 reverts landed and verified live un-gated in samples-perl @3b3dded: #2 mutex, #3 batch-sliding-window, #5 external-workflow, #6 cancellation, #7 timer, #8 waiting-for-handlers, #9 local-activity. Reverts #1 sync-activity, #4 updatable-timer, #10 context-propagation, #11 nexus DEFERRED pending the residual fixes B9/B10/B11 below (B8.2's safety valve surfaced four residual SDK bugs the B1-B7 fixes did not fully cover)
- [ ] B8.3 Update sdk-perl CLAUDE.md + README status lines to "verified live against a dev server" (do AFTER B9/B10/B11 land and the remaining reverts #1/#4/#10/#11 are un-gated)
- [ ] B8.4 (Optional) SDK diagnostic for plain-die-in-workflow -> retryable task failure; doc note on Temporalio::Exception::Application
- [ ] B8.5 Verify: sdk-perl full `prove -lj4 t` green; samples-perl `just check` green offline AND every reverted live smoke passes with the SDK on PERL5LIB

### B8 reconciliation note (do after B9/B10/B11)
B8.2's residual safety valve surfaced FOUR SDK bugs not fully covered by B1-B7:
#1 (sync fork-pool child corrupts the bridge signal fd -> "Bad file descriptor"
+ 200s hang; B4 fixed only a DIFFERENT teardown-reaper SEGV), #4 (wait_condition
WITH A TIMEOUT still wedges even though B1's plain re-park fix is present), #10
(workflow-inbound ExecuteWorkflow input built WITHOUT the start headers, so
context propagation forwards an empty header), and #11 (nexus, which shares #1's
fork-pool fd path and must be re-verified after B9). These become fix steps B9,
B10, B11. AFTER B9/B10/B11 land: revert the remaining sample workarounds (#1, #4,
#10, #11) in samples-perl and verify their un-gated live smokes, THEN do B8.3 and
B8.5.

## B9 C-FD-REAL: sync fork-pool child corrupts the bridge signal fd (#1; #11 shares it)
- [ ] B9.1 RED: subprocess-guarded integration repro mirroring the sync-activity sample (a `:Defn(...,'sync=1')` activity with real FD hygiene) that asserts the worker returns without "signal fd write failed (Bad file descriptor)" and does not hang (~200s today); fails first for the documented reason
- [ ] B9.2 Diagnose: confirm the fork-pool child closes/corrupts the bridge completion-queue signal fd (B4's reaper fix addressed a different teardown SEGV, NOT this production bug); record in ROOT-CAUSE-MAP.md
- [ ] B9.3 GREEN: set close-on-exec on the eventfd/pipe at creation in Core/Callback.pm AND/OR exclude the bridge signal fd from the Worker/Activity fork-pool child's FD-close sweep
- [ ] B9.4 REFACTOR: document the signal-fd-ownership contract at the eventfd creation site and the fork-pool FD sweep; comment cites #1
- [ ] B9.5 Verify: live repro passes un-gated (no "signal fd write failed", no hang); re-verify #11 nexus round-trip after the fd fix; full `prove -lj4 t` green

## B10 C-COND-TIMEOUT: wait_condition-with-timeout timer cancel/re-arm wedge (#4)
- [ ] B10.1 RED: replay or subprocess-guarded integration repro of the timeout-timer cancel/re-arm (arm a long durable timer, an `:Update` moves the deadline, re-arm a short timer); asserts the workflow does not wedge; fails first (B1's plain re-park fix is present, so this is a distinct timeout-timer path)
- [ ] B10.2 GREEN: fix the timeout-timer cancel/re-arm path in Runner.pm so a moved deadline cancels the stale timer and arms the new one without wedging
- [ ] B10.3 REFACTOR: unify the timeout-timer cancel/re-arm with the plain re-park path; comment cites #4
- [ ] B10.4 Verify: the timeout repro passes; B1's #3 plain re-park repro still passes; full `prove -lj4 t` green

## B11 C-ICEPT-HEADERS: workflow-inbound input missing start headers (#10)
- [ ] B11.1 RED: unit or integration repro asserting the workflow-inbound ExecuteWorkflow input carries the start headers from the InitializeWorkflow job (today Runner.pm ~1685-1690 passes only type/args/_root, so the inbound hook reads no header and the activity sees request_id=(none)); fails first
- [ ] B11.2 GREEN: populate the workflow-inbound input headers from the InitializeWorkflow job so the inbound interceptor and context propagation see the real start headers
- [ ] B11.3 REFACTOR: thread the start headers through the inbound-input build the same way the outbound path carries them; comment cites #10
- [ ] B11.4 Verify: the inbound-headers repro passes; context-propagation live smoke forwards a non-empty header (activity reads the real request_id); full `prove -lj4 t` green
