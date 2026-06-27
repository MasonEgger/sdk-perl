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
- [~] B8.2 PARTIAL: revert sample workarounds per the cleanup contract. After reconciliation pass 2 (samples-perl @0195c34, which reverted #1 sync-activity and #4 updatable-timer and verified BOTH live), 10/11 reverts have landed and been verified live un-gated: #1 sync-activity, #2 mutex, #3 batch-sliding-window, #4 updatable-timer, #5 external-workflow, #6 cancellation, #7 timer, #8 waiting-for-handlers, #9 local-activity. Only #10 context-propagation and #11 nexus remain GATED, pending the new SDK fixes B12 (#10, two gaps) and B13 (#11) below. Pass 2 surfaced THREE more precisely-instrumented SDK gaps the B1-B11 fixes did not cover: two on the activity side of context propagation (#10 -> B12) and one on the Nexus async-completion path (#11 -> B13)
- [ ] B8.3 Update sdk-perl CLAUDE.md + README status lines to "verified live against a dev server" (do AFTER B9/B10/B11 land and the remaining reverts #1/#4/#10/#11 are un-gated)
- [ ] B8.4 (Optional) SDK diagnostic for plain-die-in-workflow -> retryable task failure; doc note on Temporalio::Exception::Application
- [ ] B8.5 Verify: sdk-perl full `prove -lj4 t` green; samples-perl `just check` green offline AND every reverted live smoke passes with the SDK on PERL5LIB

### B8 reconciliation note (do after B12/B13)
B8.2's residual safety valve was first read as FOUR residual SDK bugs; the B9
investigation revised that down to THREE real SDK fix steps plus one samples-perl
fix. Those landed as B10 (#4 timeout-timer) and B11 (#10 workflow-inbound header),
plus the samples-perl #1 import fix. Reconciliation pass 2 (samples-perl @0195c34)
then reverted #1 and #4 and verified both live, AND surfaced THREE more
precisely-instrumented SDK gaps blocking the last two reverts:
- #10 context propagation still reads `request_id=(none)` live, for TWO reasons on
  the ACTIVITY side: (A) the activity-inbound interceptor input has no headers
  (ActivityDispatcher.pm `_handle_start` never reads the Start task's
  `header_fields`), and (B) header double-encoding (the outbound path runs an
  already-Payload header value through `to_payload`, so the inbound hook gets a
  doubly-encoded Payload). Tracked as B12.
- #11 (nexus) `:WorkflowRunOperation` async never completes for the caller:
  OperationContext.pm `WorkflowRunOperationContext::start_workflow` issues a plain
  `start_workflow` with NO completion callback / operation token / event links, so
  the backing workflow completes but the caller's operation parks forever. The fd
  theory for #11 is CONFIRMED DEAD (it shares no fd path with #1; there is no SDK
  fd bug). Tracked as B13.
AFTER B12/B13 land: do the final samples pass to revert #10 (context-propagation)
and #11 (nexus) in samples-perl and verify their un-gated live smokes, THEN do
B8.3 (flip the docs to "verified live against a dev server") and B8.5 (final
green-suite + all-reverts-pass verification).

## B9 C-FD-REAL (RE-SCOPED 2026-06-26): NO SDK bug. #1 is a samples-perl import bug; fix moves to B8 reconciliation #1.
- [x] B9.1 DONE (diagnosis corrected: NOT an SDK bug). RED repro built; a faithful sync-activity repro fails the SAME way IN-PROCESS with NO fork, so a fork-pool FD sweep cannot be the cause. The parent's signal fd stays OPEN throughout (dup probe succeeds every tick); a CORRECT sync `:Defn(...,'sync=1')` activity runs cleanly through the fork pool live (returns 25); the eventfd is already EFD_CLOEXEC.
- [x] B9.2 DONE (diagnosis corrected). Real root cause of #1: samples-perl `sync-activity/lib/SyncActivity/Activities.pm` does `use SyncActivity::Compute qw(count_primes)` at file scope (package main), so the unqualified call inside `class SyncActivity::Activities` resolves to an undefined sub; the activity dies every dispatch and the unlimited-retry policy loops ~200s. The "signal fd N write failed (Bad file descriptor)" line is a BENIGN teardown-race artifact (printed after the await already failed). Recorded in ROOT-CAUSE-MAP.md.
- [x] B9.3 N/A (no SDK bug to fix). The eventfd is already EFD_CLOEXEC and the fd path is verified healthy. The actual #1 fix is a samples-perl change tracked under B8 reconciliation #1 (qualify the call to `SyncActivity::Compute::count_primes(...)` or import into the activity's own package).
- [x] B9.4 N/A (no SDK refactor needed). Optional cosmetic-only nice-to-have noted in plan.md Step B9: have the fork-pool child exclude the inherited bridge signal fd from its FD-close sweep to silence the misleading EBADF-on-close teardown noise. NOT a bug.
- [x] B9.5 N/A (no SDK fix to verify). #1's fix is verified in samples-perl under B8 reconciliation #1. #11 (nexus) shares NO fd path with #1 and must be re-verified INDEPENDENTLY on its own registration/sample, not on a non-existent fd fix.

## B10 C-COND-TIMEOUT: wait_condition-with-timeout timer cancel/re-arm wedge (#4)
- [x] B10.1 RED: subprocess-guarded integration repro (t/integration/repro_condition_timeout_rearm.t) of the updatable-timer pattern (arm a long timer behind a wait_condition timeout, a `move` :Update pulls the deadline nearer, re-arm a short timer). FAILED first on HEAD, but NOT for the hypothesized re-arm reason: the deterministic replay repro (t/replay/repro_condition_timeout_rearm.t) proves the timer cancel/re-arm command sequence (exactly one StartTimer + one CancelTimer for the moved deadline) is already CORRECT on HEAD. The real wedge is `Temporalio::Workflow::now` tripping the determinism guard (DateTime->from_epoch calls the trapped `gmtime` builtin), so every live activation calling now in its loop task-fails. Captured as a deterministic unit repro by extending SafeNow/T-det-4 (determinism_guard.t) to actually exercise now() under the installed guard. RED-confirmed by reverting the fix.
- [x] B10.2 GREEN: fix is in Temporalio::Workflow::now (Workflow.pm), not the re-arm path: construct the DateTime under Unsafe::illegal_call_tracing_disabled so now honors the now/time/random self-exemption (T-det-4 / spec §29.4) and no longer task-fails under the live guard. The timer cancel/re-arm in Runner.pm needed no change (replay proves it correct).
- [x] B10.3 REFACTOR: the timeout-timer cancel/re-arm already shares ONE path with the plain re-park (Runner.pm _check_conditions cancels the entry's timer and filters the live list, the B1 unification), so there is nothing further to unify there. Closed the test gap instead: SafeNow's T-det-4 self-exemption now actually calls now() (it claimed now was exempt but never tested it). Comments in now/SafeNow/the test cite #4.
- [x] B10.4 Verify: the integration repro passes (10s, would wedge 100s unfixed); the new replay repro and the deterministic determinism_guard.t now-exemption pass; B1's #3 plain re-park repro (repro_check_conditions.t) still passes; full `prove -lj4 t` green (99 files, 540 tests, exit 0).

## B11 C-ICEPT-HEADERS: workflow-inbound input missing start headers (#10)
- [x] B11.1 RED: unit or integration repro asserting the workflow-inbound ExecuteWorkflow input carries the start headers from the InitializeWorkflow job (today Runner.pm ~1685-1690 passes only type/args/_root, so the inbound hook reads no header and the activity sees request_id=(none)); fails first. Landed t/unit/workflow_inbound_headers.t (header-spy WorkflowInbound captures the execute_workflow input headers off an InitializeWorkflow job carrying _request_id; failed before the fix with the header key absent)
- [x] B11.2 GREEN: populate the workflow-inbound input headers from the InitializeWorkflow job so the inbound interceptor and context propagation see the real start headers. Runner.pm ~1685 now passes headers => { %{ $init->headers // {} } } into the ExecuteWorkflow input
- [x] B11.3 REFACTOR: thread the start headers through the inbound-input build the same way the outbound path carries them (mirrors the schedule_activity Str=>Payload header map at ~L497); comment cites #10
- [x] B11.4 Verify: the inbound-headers repro passes; context-propagation live smoke (t/integration/repro_interceptor_headers.t) forwards a non-empty start header and the workflow-inbound hook reads the real request id, never (none); B7 worker_inbound_interceptor.t still green; full `prove -lj4 t` green (101 files, 545 tests)

## B12 C-ICEPT-ACTIVITY-HEADERS: activity-inbound input missing headers + header double-encoding (#10, two gaps)
- [ ] B12.1 RED: unit/integration repro asserting (a) the activity-inbound ExecuteActivity input carries the Start task's header_fields (proto field 6), AND (b) a header set at start round-trips to the activity-inbound hook un-double-encoded; fails first for the documented reasons (header ABSENT on activity-inbound; where present, its value is a doubly-encoded Payload)
- [ ] B12.2 GREEN (gap A): thread the activity Start `header_fields` into the ExecuteActivity interceptor input in ActivityDispatcher.pm `_handle_start` (sync branch ~L158, async branch ~L182) so `$input->headers` is populated in the activity-inbound hook
- [ ] B12.3 GREEN (gap B): settle the interceptor-header representation so headers pass through as Payloads consistently in BOTH directions (outbound and inbound), matching sdk-python; do not run an already-Payload header value back through `to_payload` (no double-encode)
- [ ] B12.4 REFACTOR: one header-representation contract shared by the outbound and inbound paths (pass-through Payload, never re-encoded); comment cites #10
- [ ] B12.5 Verify: the activity-inbound header repro passes; B7's workflow_inbound_interceptor.t and B11's workflow_inbound_headers.t still pass; full `prove -lj4 t` green

## B13 C-NEXUS-CALLBACK: :WorkflowRunOperation async completion callback (#11)
- [ ] B13.1 RED: subprocess-guarded live repro of a `:WorkflowRunOperation` caller->handler round-trip asserting the caller's operation resolves with the backing workflow's result; today it parks forever / times out (server shows `Pending Nexus Operations: 1`; backing workflow's `WorkflowExecutionStarted` has `completionCallbacks: null`)
- [ ] B13.2 Investigate: whether the pinned c-bridge / proto already lets Perl populate the StartWorkflowExecution request's `completion_callbacks` (+ Nexus operation token / workflow event links) from the Nexus operation context (likely yes, Perl-side only, like B6's Nexus poll which needed no shim); if shim work IS required, follow the CLAUDE.md memory guard (CARGO_BUILD_JOBS=2, foreground, cargo test + cbindgen regen + Alien rebuild)
- [ ] B13.3 GREEN: attach the Nexus async completion callback (+ operation token + workflow event links) to the WorkflowRunOperation backing-workflow start in OperationContext.pm `WorkflowRunOperationContext::start_workflow` (~L76-84) so the server notifies the caller on completion
- [ ] B13.4 REFACTOR: the callback/token/links wiring lives in one place on the WorkflowRunOperation start path; comment cites #11
- [ ] B13.5 Verify: the live round-trip repro passes (caller's operation resolves with the backing workflow's result); B6's repro_nexus.t still passes; full `prove -lj4 t` green (all three nexus samples use WorkflowRunOperation, so this unblocks all three)
