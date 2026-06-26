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
- [ ] B2.1 RED: create repro_cancel_commands.t (single CancelWorkflowExecution) + repro_wait_any_race.t (replay asserts emitted command list, not in-process: no double-complete / no cancel of resolved seq); fail first
- [ ] B2.2 GREEN: emit at most one workflow-terminal command per activation; no RequestCancel for an already-resolved wait_any loser
- [ ] B2.3 REFACTOR: centralize terminal-command guarding; comment cites #6/#7
- [ ] B2.4 Verify: both replay repros pass; full `prove -lj4 t` green; existing cancellation replays still pass

## B3 C-CANCEL-LIVE: throwable Cancelled + clean cancel-mid-update (#5, #8)
- [ ] B3.1 RED: create repro_cancel_live.t (never-true wait_condition -> Cancelled) + repro_cancel_mid_update.t (SUBPROCESS-GUARDED ~30s; mid-:Update hangs ~183s today); fail first
- [ ] B3.2 GREEN: wait_condition + update-await (Runner.pm ~2667) raise Temporalio::Exception::Cancelled via the Future-subclass pattern
- [ ] B3.3 REFACTOR: every internal await (timer/activity/condition/update/child) routes cancel through throwable-Cancelled; comment cites #5/#8
- [ ] B3.4 Verify: both live repros pass un-gated; re-run B1+B2 repros; full `prove -lj4 t` green

## B4 C-FD: signal-fd CLOEXEC / fork-pool FD hygiene (#1, #2) [SHIM]
- [ ] B4.1 RED: create repro_fd_signal.t (sync fork-pool activity returns) + repro_external_signal.t (two cross-workflow signals delivered); SUBPROCESS-GUARDED (FD corruption wedges the worker); fail first
- [ ] B4.2 GREEN (shim): FD_CLOEXEC on eventfd + O_CLOEXEC on pipe fds at lib.rs ~1670; cargo test; regen cbindgen header; rebuild+reinstall Alien bridge (memory guard, nm -D)
- [ ] B4.3 GREEN (Perl, if needed): ActivityDispatcher fork-pool child excludes the bridge signal fd from its FD-close sweep
- [ ] B4.4 REFACTOR: document bridge-fd ownership (runtime owns it; children never touch it)
- [ ] B4.5 Verify: both live repros pass un-gated; cargo test green; full `prove -lj4 t` green; bridge symbols present

## B5 C-LOCALACT: fix execute_local_activity segfault (#9)
- [ ] B5.1 RED: create repro_local_activity.t (plain local activity returns, no exit 139) + a timeout+retry variant; SUBPROCESS-GUARDED (SEGV exit 139); fail first
- [ ] B5.2 Diagnose: locate the segfault origin (Perl-side resolution vs shim path); record in ROOT-CAUSE-MAP.md + flag shim-touching or not
- [ ] B5.3 GREEN: minimal fix at the identified layer (memory guard + Alien rebuild if shim)
- [ ] B5.4 REFACTOR: boundary guard so a regression is a clean error, not a SEGV
- [ ] B5.5 Verify: live repro passes; eager-workflow-start local-activity path works live; full `prove -lj4 t` green

## B6 C-NEXUS: enable Nexus serving + wire the task poller (#11)
- [ ] B6.1 RED: create repro_nexus.t (one-worker caller->handler round-trip resolves); SUBPROCESS-GUARDED (blocks forever today); fail first
- [ ] B6.2 GREEN: set enable_nexus from registered Nexus services (not hardcoded 0) and wire the Nexus task poll loop (memory guard + Alien rebuild if shim)
- [ ] B6.3 REFACTOR: gate enable_nexus on actual Nexus registration; comment cites #11
- [ ] B6.4 Verify: live round-trip passes; non-Nexus integration tests unaffected; full `prove -lj4 t` green

## B7 C-ICEPT: invoke worker inbound interceptor chains (#10)
- [ ] B7.1 RED: worker_inbound_interceptor.t spy asserts inbound execute_activity/execute_workflow (+ signal/query/update) invoked in order; repro_interceptor_inbound.t live smoke
- [ ] B7.2 GREEN: wire built inbound chains into the activity dispatcher + workflow activation dispatch
- [ ] B7.3 REFACTOR: ordering matches the outbound contract (client then worker, outermost first); comment cites #10
- [ ] B7.4 Verify: unit spy + live smoke pass; full `prove -lj4 t` green

## B8 Cleanup: sample fix, revert workarounds, docs live-verified
- [ ] B8.1 activity-choice sample fix (samples-perl): Menu returns undef; Workflow raises non-retryable Application; update t/01 + confirm t/02-smoke fast
- [ ] B8.2 Revert sample workarounds per the cleanup contract (#1-#11), verifying each un-gated live smoke passes
- [ ] B8.3 Update sdk-perl CLAUDE.md + README status lines to "verified live against a dev server"
- [ ] B8.4 (Optional) SDK diagnostic for plain-die-in-workflow -> retryable task failure; doc note on Temporalio::Exception::Application
- [ ] B8.5 Verify: sdk-perl full `prove -lj4 t` green; samples-perl `just check` green offline AND every reverted live smoke passes with the SDK on PERL5LIB
