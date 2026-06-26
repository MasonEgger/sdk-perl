# sdk-perl live-hardening plan (bug-fix phase)

TDD blueprint for fixing the live-SDK defects in
`sdk-perl-issues-from-samples.md`. This is a bug-fix / live-hardening phase, not
feature work: every item is a behavior that passes the unit and replay suites
today but fails against a real `temporal server start-dev`. The spec for this
plan is `sdk-perl-issues-from-samples.md`.

## Prime directives for this phase

1. **Reproduce before patching, inside each fix step.** No fix is written until a
   RED test reproduces the bug and fails for the documented reason. Reproduction
   and fix live in the SAME step (RED, then GREEN, then commit), so every commit
   leaves the suite green and the repro ships as permanent passing coverage. The
   issues doc is explicit these were not all independently re-reproduced, so the
   RED step is also the triage that confirms the bug is real and pins the root.
2. **Fix by root cause, not by symptom.** The 11 bugs collapse into 6 clusters
   (below). A cluster is one fix with one or more reproducers, not N edits.
3. **Every patch ships its reproducer as permanent coverage.** These bugs escaped
   the green unit/replay suites: there is a live-integration coverage gap. Each
   repro stays in `sdk/t/integration/` (timing/live paths) or `sdk/t/replay/`
   (deterministic command-sequence paths) so the next refactor cannot silently
   regress it. Closing that coverage gap is part of "done."
4. **Crash and hang repros run in a timeout-guarded subprocess.** Several bugs
   SEGV the worker (#7, #9) or hang it (#1, #3, #6, #8, #11). A repro that ran the
   dangerous workflow in-process would crash or hang the whole `prove` run, not
   produce a clean failure. Those repros fork/exec the worker plus workflow in a
   child under a hard timeout and assert the child exited 0 within the bound, so
   RED is a clean failing assertion (child crashed or timed out), never a harness
   crash. Prefer a deterministic `sdk/t/replay/` repro (asserts on the emitted
   command list, no live worker) wherever the bug is command-sequence shaped.
5. **Every commit is green; the suite never goes red.** This is the autonomous
   per-commit gate. It is why the repro lands together with its fix in one commit
   and B0 commits no failing tests.
6. **Shim changes follow the memory guard.** The signal-FD fix (and possibly the
   Nexus and local-activity fixes) touch `ext/temporalio-perl-bridge/src/lib.rs`.
   Per CLAUDE.md: `CARGO_BUILD_JOBS=2`, FOREGROUND builds, then `cargo test`,
   regenerate the cbindgen header, and rebuild the installed
   `Alien::Temporalio::PerlBridge` so the SDK loads the new symbols.

## Root-cause clusters

| Cluster | Bugs | Primary files | Test type | Shim? |
|---|---|---|---|---|
| C-COND: `_check_conditions` drops re-registered conditions | #3, #4 | `Workflow/Runner.pm` (~1351-1373) | replay | no |
| C-CANCEL-CMD: cancel emits invalid / duplicate commands, double-complete SEGV | #6, #7 | `Workflow/Runner.pm`, `Workflow/Commands.pm` | replay | no |
| C-CANCEL-LIVE: never-true wait_condition not throwable-Cancelled; client-cancel mid-update | #5, #8 | `Workflow/Runner.pm` (~2667), `Workflow/Future.pm` | integration | no |
| C-FD: fork-pool child closes the bridge signal fd; cross-workflow signal stall | #1, #2 | `ext/temporalio-perl-bridge/src/lib.rs` (~1670), `Worker/ActivityDispatcher.pm` | integration | YES |
| C-LOCALACT: `execute_local_activity` segfaults the worker | #9 | `Workflow/Runner.pm`, `Worker.pm`, shim TBD | integration | maybe |
| C-NEXUS: worker hardcodes `enable_nexus => 0`, never polls Nexus tasks | #11 | `Worker.pm:424`, Nexus poller wiring | integration | maybe |
| C-ICEPT: worker inbound interceptor chains built but never invoked | #10 | `Worker.pm` (build_*_inbound), dispatch path | unit + integration | no |

The doc's cross-cutting note (items B, C, FD may share a root in the runner's
condition/teardown and the bridge signal-FD lifecycle) is why C-COND and the two
cancel clusters come first and are sequenced together: fixing the condition
rebuild may change the cancel symptoms, so re-run all cancel reproducers after
C-COND lands.

## Current Status

- [ ] B0 Triage doc: ROOT-CAUSE-MAP.md (investigation only, no failing tests)
- [ ] B1 C-COND: preserve continuation-registered conditions (#3, #4)
- [ ] B2 C-CANCEL-CMD: valid, de-duplicated cancel command sequences (#6, #7)
- [ ] B3 C-CANCEL-LIVE: throwable Cancelled + clean cancel-mid-update (#5, #8)
- [ ] B4 C-FD: signal-fd CLOEXEC / fork-pool FD hygiene (#1, #2) [SHIM]
- [ ] B5 C-LOCALACT: fix execute_local_activity segfault (#9)
- [ ] B6 C-NEXUS: enable Nexus serving + wire the task poller (#11)
- [ ] B7 C-ICEPT: invoke worker inbound interceptor chains (#10)
- [ ] B8 Cleanup: activity-choice sample fix, revert sample workarounds, docs live-verified

---

## Step B0: Triage doc (ROOT-CAUSE-MAP.md)

**NOTE**: Doc-only step: NO test files and NO source changes, so the suite stays
green and the commit passes the per-commit gate. The reproductions are written
inside each fix step (B1-B7), where they land green with the fix. The value here
is confirming the clustering, pinning the suspected root file:line, and deciding
Perl-side vs shim-side BEFORE the fixes start. Live integration tests already
exist under `sdk/t/integration/` (using `Temporalio::Test::DevServer` + the
`Temporalio::Test::Worker` retry helpers, `skip_all` when the `temporal` CLI is
absent, phased serially via `sdk/.proverc`); replay tests live under
`sdk/t/replay/` and need no server. The fix steps reuse both.

```text
1. Investigate each cluster against the code (read-only) and the issues doc:
   - Locate the suspected root file:line per cluster: _check_conditions in
     Workflow/Runner.pm (~1351); the cancel/teardown path (~2667); the shim
     signal_fd alloc in ext/temporalio-perl-bridge/src/lib.rs (~1670);
     enable_nexus in Worker.pm:424; the inbound-chain build-vs-dispatch gap in
     Worker.pm (~246-251); the local-activity exec path (Runner.pm / Worker.pm).
   - Where a quick read is ambiguous (the local-activity segfault layer, whether
     the Nexus poller needs shim support), record the open question to resolve in
     that fix step rather than guessing now.
2. Write ROOT-CAUSE-MAP.md: a table mapping each bug # to its cluster, the planned
   repro test path, the suspected root file:line, Perl-side vs shim-side, and the
   test type (replay vs subprocess-guarded integration). Flag any bugs that look
   like the same root (candidates to fix together).
3. GREEN: none. No test or source files change in this step; the deliverable is
   ROOT-CAUSE-MAP.md only.
4. Verify: full `prove -lj4 t` stays green (nothing changed but the doc); commit
   ROOT-CAUSE-MAP.md plus the session summary.
```

---

## Step B1: C-COND preserve continuation-registered conditions (#3, #4)

**NOTE**: `Temporalio/Workflow/Runner.pm` `_check_conditions` (~1351-1373) rebuilds
its pending list with `@conditions = @still`, which drops a `wait_condition`
registered synchronously by a continuation that ran inside the same
`_check_conditions` pass. This is the "deepest find" and is replay-testable
(deterministic), so prefer replay tests over live ones here.

```text
1. RED: Create sdk/t/replay/repro_check_conditions.t (a replay regression; confirm
   it FAILS for the documented reason before GREEN):
   - Assert that when a completion wakes the body and the continuation registers a
     fresh wait_condition during _check_conditions, the new condition survives the
     pending-list rebuild and is re-evaluated.
   - Add the #4 variant: arm a long timer, an :Update wakes the predicate, re-arm a
     short timer; assert the re-armed condition is honored (no wedge).
2. GREEN: Fix _check_conditions to merge conditions registered DURING the pass
   instead of overwriting the list with @still. Re-snapshot or append the
   newly-registered conditions before assigning, so a synchronous re-park is not
   lost.
3. REFACTOR: Make the condition-list mutation re-entrancy-safe (a condition added
   while iterating is tracked deterministically); add a comment citing #3.
4. Verify: both replay repros pass; full `prove -lj4 t` green; no behavior change
   for the existing replay/wait_condition tests.
```

---

## Step B2: C-CANCEL-CMD valid, de-duplicated cancel commands (#6, #7)

**NOTE**: Two command-emission defects, both replay-testable. #6: a try_cancel
activity under whole-workflow cancel emits a duplicate CancelWorkflowExecution.
#7: a `Future->wait_any` timer-vs-activity race emits cancel + double-complete and
the timer-wins path SEGVs the worker. Run AFTER B1, since the condition fix may
alter the activation sequence.

```text
1. RED: Create sdk/t/replay/repro_cancel_commands.t and sdk/t/replay/repro_wait_any_race.t
   (replay regressions; confirm both FAIL for the documented reason before GREEN):
   - Assert a try_cancel activity under workflow cancel yields a command list with
     exactly one CancelWorkflowExecution and a single RequestCancelActivity.
   - repro_wait_any_race.t: a wait_any(timer, activity); on the timer-wins path
     assert exactly one CompleteWorkflowExecution and no RequestCancel for an
     already-resolved seq (today: cancel + double-complete). #7 SEGVs in-process,
     so this asserts on the EMITTED COMMAND LIST from a replay (deterministic, no
     live worker), which surfaces the double-complete without crashing the suite.
2. GREEN: De-duplicate terminal commands in the runner / Commands.pm: emit at most
   one workflow-terminal command (Complete/Cancel/Fail) per activation; when the
   loser of a wait_any is already resolved, do not emit a RequestCancel for it.
3. REFACTOR: Centralize "terminal command already emitted" guarding so all three
   terminal commands share it; comment citing #6/#7.
4. Verify: both replay repros pass; full `prove -lj4 t` green; the existing
   cancellation replay tests still pass.
```

---

## Step B3: C-CANCEL-LIVE throwable Cancelled + clean cancel-mid-update (#5, #8)

**NOTE**: #5: parking on a never-true `wait_condition` and cancelling yields a raw
"was cancelled" string, not a throwable `Temporalio::Exception::Cancelled` routed
to CancelWorkflowExecution; today you must park on a durable timer instead. #8: a
client cancel landing while an `:Update` handler is mid-flight (`Runner.pm` ~2667)
raises a raw cancelled Future and hangs ~183s. The prior lesson applies: a
cancellable workflow awaitable must be a Future SUBCLASS whose `cancel` fails with
the Temporal `Cancelled` exception, never native `->cancel`. These are timing
paths, so use live integration tests.

```text
1. RED: Create sdk/t/integration/repro_cancel_live.t and repro_cancel_mid_update.t
   (SUBPROCESS-GUARDED per directive 4: the mid-update path hangs ~183s today, so
   run the worker+cancel in a child under a ~30s hard timeout and assert clean
   exit; confirm both FAIL for the documented reason before GREEN):
   - Assert a workflow parked on a never-true wait_condition, when client-cancelled,
     ends Cancelled (CancelWorkflowExecution) without a durable-timer workaround.
   - repro_cancel_mid_update.t: start an :Update handler that awaits, then
     client-cancel the run mid-update; assert a clean WorkflowFailure/Cancelled
     surfaces within the timeout (today: ~183s hang trips the guard).
2. GREEN: Make wait_condition's awaitable (and the update-dispatch await at
   Runner.pm ~2667) raise Temporalio::Exception::Cancelled on cancel via the
   Future-subclass pattern, so the body unwinds to CancelWorkflowExecution instead
   of leaking a raw cancelled Future.
3. REFACTOR: Ensure every internal workflow await (timer, activity, condition,
   update, child) routes cancel through the same throwable-Cancelled path; comment
   citing #5/#8.
4. Verify: both live repros pass un-gated; full `prove -lj4 t` green; re-run the B1
   and B2 repros (cross-cluster regression check).
```

---

## Step B4: C-FD signal-fd CLOEXEC / fork-pool FD hygiene (#1, #2) [SHIM]

**NOTE**: SHIM-TOUCHING. The shim allocates the completion-queue `signal_fd`
(eventfd, or pipe write-end) at `ext/temporalio-perl-bridge/src/lib.rs` ~1670 and
"borrows it and never closes it." A sync-activity fork-pool child doing normal FD
hygiene closes that inherited fd, corrupting the parent worker loop ("signal fd N
write failed: Bad file descriptor"). #2 (cross-workflow signal stall after the
first grant) is the same fd. Fix is to keep the bridge fd out of the child:
set FD_CLOEXEC / O_CLOEXEC on the eventfd and pipe fds (so exec/child cannot use
them) and/or have the fork pool record and never close the bridge fd. Follow the
CLAUDE.md memory guard + Alien rebuild.

```text
1. RED: Create sdk/t/integration/repro_fd_signal.t and repro_external_signal.t
   (SUBPROCESS-GUARDED per directive 4: FD corruption wedges the worker, so run the
   worker+workflow in a child under a hard timeout and assert clean exit; confirm
   both FAIL for the documented reason before GREEN):
   - Assert a sync fork-pool activity that closes inherited FDs still returns a
     result (no "signal fd write failed").
   - repro_external_signal.t: workflow A signals workflow B twice via
     get_external_workflow_handle; assert both signals are delivered (today the
     second stalls and trips the guard).
2. GREEN (shim): set FD_CLOEXEC on the eventfd and O_CLOEXEC on the pipe fds where
   the queue's signal_fd is created (~1670); rebuild per the memory guard
   (CARGO_BUILD_JOBS=2, foreground, cargo test, regen cbindgen header, rebuild +
   reinstall Alien::Temporalio::PerlBridge; nm -D to confirm symbols).
3. GREEN (Perl, if still needed): in Worker/ActivityDispatcher.pm's fork-pool child
   setup, record the bridge signal fd and exclude it from the child's FD-close
   sweep.
4. REFACTOR: document the bridge-fd ownership contract (only the runtime owns the
   signal fd; children never touch it).
5. Verify: both live repros pass un-gated; cargo test green; full `prove -lj4 t`
   green; confirm the installed bridge exports the expected symbols.
```

---

## Step B5: C-LOCALACT fix execute_local_activity segfault (#9)

**NOTE**: A live `execute_local_activity` segfaults the worker (exit 139) even for
a plain activity, while the same activity run as a normal (remote) activity is
green and the SDK's own local-activity coverage is replay-only. Root cause is
unknown: diagnose first and decide Perl-side vs shim-side. If shim, follow the
memory guard.

```text
1. RED: Create sdk/t/integration/repro_local_activity.t (SUBPROCESS-GUARDED per
   directive 4: this SEGVs the worker exit 139, so run the worker in a child and
   assert exit 0; confirm it FAILS for the documented reason before GREEN):
   - Assert a workflow that runs one execute_local_activity returns the activity
     result and the child worker process exits cleanly (no SEGV / exit 139).
   - Add a second case with start_to_close_timeout + a retry_policy to exercise the
     local-activity backoff loop.
2. Diagnose: capture where the segfault originates (Perl-side local-activity
   resolution in Runner.pm / Worker.pm vs a shim local-activity path). Record the
   finding in ROOT-CAUSE-MAP.md and state whether the fix is shim-touching.
3. GREEN: Apply the minimal fix at the identified layer. If shim, follow the
   CLAUDE.md memory guard + Alien rebuild.
4. REFACTOR: add an assertion/guard at the boundary that previously crashed so a
   regression surfaces as a clean error, not a SEGV.
5. Verify: the live repro passes; eager-workflow-start's local-activity path also
   works live; full `prove -lj4 t` green.
```

---

## Step B6: C-NEXUS enable Nexus serving + wire the task poller (#11)

**NOTE**: `Worker.pm:424` hardcodes `enable_nexus => 0`, so the worker never polls
Nexus tasks; a handler worker cannot serve operations and a caller's result blocks
forever. The CLAUDE.md notes the Nexus dispatcher is shim-adjacent (P9.2), so a
Nexus task poll loop may need shim wiring; confirm during diagnosis.

```text
1. RED: Create sdk/t/integration/repro_nexus.t (SUBPROCESS-GUARDED per directive 4:
   the caller blocks forever today, so run the round-trip in a child under a hard
   timeout and assert clean exit; confirm it FAILS for the documented reason before
   GREEN):
   - Register a Nexus service + operation handler and a caller workflow on one
     worker; assert the caller's execute_nexus_operation resolves with the handler
     result (today: blocks and trips the guard). Gate only on a configured endpoint
     if the test server requires it, otherwise run by default.
2. GREEN: Set enable_nexus based on whether the worker has registered Nexus
   services (not hardcoded 0), and wire the Nexus task poll loop so handler
   operations are serviced. If the poller needs shim support, follow the memory
   guard + Alien rebuild.
3. REFACTOR: gate enable_nexus on actual Nexus registration so non-Nexus workers
   are unaffected; comment citing #11.
4. Verify: the live caller->handler round-trip passes; full `prove -lj4 t` green;
   non-Nexus integration tests unaffected.
```

---

## Step B7: C-ICEPT invoke worker inbound interceptor chains (#10)

**NOTE**: `Worker.pm` builds `build_activity_inbound`/`build_workflow_inbound`
(~246-251) but the dispatch path never calls the resulting chain; only the
client-outbound chain is wired. This is a missing-wiring gap, not a crash, and is
unit-testable with a spy interceptor plus a live smoke.

```text
1. RED: Write sdk/t/unit/worker_inbound_interceptor.t (or extend the interceptor
   unit test):
   - Register a spy WorkflowInbound + ActivityInbound interceptor; dispatch an
     activity task and a workflow activation through the worker's dispatch path;
     assert the inbound execute_activity / execute_workflow (and
     handle_signal/handle_query/handle_update) methods were invoked in order.
   - sdk/t/integration/repro_interceptor_inbound.t: an end-to-end run that asserts
     an inbound interceptor observed the activity and workflow execution.
2. GREEN: Wire the built inbound chains into the activity dispatcher and workflow
   activation dispatch so execution flows through the chain to the root impl.
3. REFACTOR: ensure ordering (client-supplied then worker-supplied, outermost
   first) matches the outbound contract; comment citing #10.
4. Verify: the unit spy test and live smoke pass; full `prove -lj4 t` green.
```

---

## Step B8: Cleanup: sample fix, revert workarounds, docs live-verified

**NOTE**: After the SDK fixes land, the samples must go back to idiomatic code (the
issues doc's cleanup contract) and the docs can finally claim live-verified. The
activity-choice fix is a samples-perl change, not an SDK change.

```text
1. activity-choice sample fix (in ../samples-perl):
   - activity-choice/lib/ActivityChoice/Menu.pm: return undef for an unknown/empty
     choice instead of die (keep Menu SDK-free).
   - activity-choice/lib/ActivityChoice/Workflow.pm: when resolve returns undef,
     raise Temporalio::Exception::Application->throw(type=>'UnknownBeverage',
     non_retryable=>1).
   - Update activity-choice/t/01-*.t to assert resolve('nope') returns undef; confirm
     t/02-smoke.t resolves fast as a WorkflowFailure (no timeout) with the SDK present.
2. Revert each sample workaround per the cleanup contract, one box at a time,
   verifying the now-un-gated live smoke passes against a dev server:
   - #1 sync-activity: drop TEMPORAL_SYNC_ACTIVITY_LIVE gate.
   - #2 mutex: drop MUTEX_SMOKE gate; verify full multi-caller hand-off.
   - #3 batch-sliding-window: restore the snapshot wait_condition form.
   - #4 updatable-timer: drop TEMPORAL_UPDATABLE_TIMER_LIVE gate.
   - #5 external-workflow: drop the durable-timer park; use never-true wait_condition.
   - #6 cancellation: switch abandon back to try_cancel.
   - #7 timer: restore Future->wait_any.
   - #8 waiting-for-handlers(-and-compensation): drive the live smoke with a real
     client cancel mid-update.
   - #9 local-activity / eager-workflow-start: drop TEMPORAL_SMOKE_LOCAL_ACTIVITY guard.
   - #10 context-propagation: drop the explicit context-forward; rely on the inbound
     interceptor.
   - #11 nexus-*: drop the endpoint/enable_nexus gating; verify the live round-trip.
3. Update sdk-perl docs to claim live-verified: CLAUDE.md status line and
   README.md status block change from "unit and replay suites green" to "verified
   live against a dev server" once all repros pass.
4. (Optional, lower priority) SDK diagnostic: a clearer message when a plain die in
   workflow code becomes a retryable task failure, plus a doc note that
   business/validation errors should be Temporalio::Exception::Application.
5. Verify: full `prove -lj4 t` green in sdk-perl; samples-perl `just check` green
   offline AND every reverted live smoke passes with the SDK on PERL5LIB.
```

---

## Implementation Guidelines

- **One step per commit, always green.** B0 is one commit (the map). Each fix step
  B1-B7 is one commit carrying its repro AND its fix, so the repro lands green and
  the suite never goes red. B8's reverts commit per the project process. Shim steps
  fold the cargo test + cbindgen regen + Alien rebuild into the same commit.
- **Crash/hang repros are subprocess-guarded** (directive 4): run the dangerous
  worker+workflow in a child under a hard timeout, assert exit 0; never in-process.
- **Replay over live where deterministic.** C-COND and C-CANCEL-CMD are
  command-sequence bugs: prefer `sdk/t/replay/` repros (no server, no flakiness).
  Use `sdk/t/integration/` only for genuine timing/live paths (C-CANCEL-LIVE,
  C-FD, C-LOCALACT, C-NEXUS, and the C-ICEPT live smoke).
- **Live tests follow the existing pattern.** Reuse `Temporalio::Test::DevServer`,
  the `Temporalio::Test::Worker` retry helpers, and the `.proverc` serial-integration
  phasing. Tests `skip_all` cleanly when the `temporal` CLI is absent.
- **Memory guard for shim builds.** `CARGO_BUILD_JOBS=2`, foreground, retry once at
  jobs=1 on OOM; never background a build. Rebuild + reinstall the Alien bridge so
  the SDK loads new symbols (`nm -D` to confirm).
- **Cross-cluster regression checks.** After B1-B3 (the shared Runner.pm roots),
  re-run all cancel/condition repros together; a fix in one may move another.
- **Do not weaken the existing suites.** No repro test may be made to pass by
  loosening an existing assertion. If a fix changes existing replay golden output,
  justify it in the commit message.

## Success Metrics

- Each cluster's repro lands green with its fix and remains in the suite as
  permanent `t/integration` / `t/replay` coverage.
- `prove -lj4 t` is green in sdk-perl with every repro un-gated (the live-coverage
  gap is closed).
- Every cleanup-contract box in `sdk-perl-issues-from-samples.md` is checked: the
  matching sample is back to idiomatic code and its live smoke passes un-gated.
- samples-perl `just check` is green offline and with the SDK on PERL5LIB.
- CLAUDE.md and README status lines are updated to "verified live against a dev
  server."
