# sdk-perl issues surfaced while building samples-perl

Compiled 2026-06-26 from the live-SDK verification done during the samples-perl
catalog build. Each item was hit by an actual live smoke against
`temporal server start-dev` with the SDK on `PERL5LIB`. Every one was worked
around in the *sample* (gated opt-in live smoke, or a different idiom) and the
sample logic was proven offline. None of these were patched in sdk-perl. Source
detail lives in the per-step files under
`samples-perl/.ai-sessions/session-*.md` and `lessons.md`.

Severity tags are my read, not the SDK team's.

**Why this matters beyond the bugs.** Every item below forced a *workaround in a
sample*, and a workaround in teaching material is a smell: a sample is supposed
to show the idiomatic SDK usage, not a hack around an SDK defect. The real fix is
SDK-side. Once a bug is fixed, the matching sample should be reverted to its
natural form so it teaches the right thing. The cleanup contract below pairs each
bug with the exact workaround to delete after the fix lands.

## Cleanup contract: workarounds to delete once the SDK is fixed

Each box is a sample carrying a workaround *only* because of the matching bug
above. Fixing the SDK should let the sample go back to idiomatic code; check the
box when the workaround is removed.

- [ ] **#1 sync-activity** — remove the `TEMPORAL_SYNC_ACTIVITY_LIVE` opt-in gate
  so the live fork-pool smoke runs by default.
- [ ] **#2 mutex** — remove the `MUTEX_SMOKE` gate and verify the full
  multi-caller lock hand-off live (today only the first grant is verified).
- [ ] **#3 batch-sliding-window** — the coordinator parks on a `can_admit ||
  page_drained` live-state predicate purely to dodge the dropped re-park; once
  `_check_conditions` preserves continuation-registered conditions, the natural
  snapshot `wait_condition` form is safe again.
- [ ] **#4 updatable-timer** — remove the `TEMPORAL_UPDATABLE_TIMER_LIVE` gate.
- [ ] **#5 external-workflow** — the "park until cancelled" path sleeps on a
  durable timer only so `Cancelled` is throwable; once a never-true
  `wait_condition` yields a throwable `Cancelled`, drop the timer.
- [ ] **#6 cancellation** — switch the activity back from `cancellation_type =>
  'abandon'` to `try_cancel` once the cancel command sequence is valid.
- [ ] **#7 timer** — replace the `on_ready` / leave-the-loser-pending race with
  the natural `Future->wait_any` once it no longer SEGVs.
- [ ] **#8 waiting-for-handlers / waiting-for-handlers-and-compensation** — drive
  the live smoke with a real client cancel mid-update (drop the deterministic
  failing-node stand-in) once cancel-mid-update yields a clean `WorkflowFailure`.
- [ ] **#9 local-activity** — remove the `TEMPORAL_SMOKE_LOCAL_ACTIVITY` gate and
  eager-workflow-start's local-activity guard once the segfault is fixed.
- [ ] **#10 context-propagation** — drop the explicit context-forward onto the
  activity call and rely on the worker inbound interceptor once it is invoked.
- [ ] **#11 nexus-hello / nexus-messaging / nexus-cancellation** — remove the
  endpoint / `enable_nexus` gating and verify the live caller->handler round-trip
  once the worker polls Nexus tasks.

Separately, the activity-choice sample needs a straight sample fix (raise a
non-retryable `Temporalio::Exception::Application` instead of `die`); see the
actionable section at the end. That one is a sample defect, not an SDK
workaround.

## A. FD / runtime-bridge corruption (high)

1. **Sync fork-pool activity closes the bridge's signal FD.** A
   `method foo :Defn('Name', 'sync=1')` fork-pool child, doing normal FD hygiene
   (closing inherited descriptors), closes the runtime bridge's signal FD. Result:
   `temporalio-perl-bridge: signal fd 13 write failed (signal dropped): Bad file
   descriptor`, the parent worker event loop is corrupted, and the workflow never
   returns (a `timeout --signal=KILL 150` wrapper exits 137).
   *Surfaced by:* sync-activity (step 11). *Repro:* run its live smoke without the
   opt-in gate.

2. **Cross-workflow signal hand-off stalls after the first grant.**
   `get_external_workflow_handle($id)->signal` delivers the first signal, but a
   second hand-off in the same run hits the same signal-fd stall and wedges.
   *Surfaced by:* mutex (step 30); related stalls in external-workflow (step 24).

## B. wait_condition re-registration dropped (high — deepest find)

3. **A wait_condition continuation that synchronously re-parks at a
   continue-as-new boundary is dropped.** When a completion wakes the workflow
   body and the continuation runs *synchronously* inside the runner's
   `_check_conditions` and registers a fresh `wait_condition` in place,
   `_check_conditions` rebuilds its pending list with `@conditions = @still`
   (sdk `Temporalio/Workflow/Runner.pm` ~1351-1373) and drops the
   continuation-registered condition. The final child's `reportComplete` then
   never wakes the coordinator: it sits Running with no pending tasks and no
   `ContinueAsNewWorkflowExecution` command, hanging forever.
   *Surfaced by:* batch-sliding-window (step 25). *Workaround in sample:* park on
   a single predicate over live state (`can_admit || page_drained`) so
   intermediate completions leave it false and never trigger a synchronous re-park.

4. **wait_condition timer re-arm wedge (same family).** Arm a long timer, an
   `:Update` wakes the predicate, then re-arm a short timer -> wedge.
   *Surfaced by:* updatable-timer (step 31). Gated opt-in.

## C. Cancellation propagation produces invalid command sequences / raw futures (high)

5. **A "park until cancelled" workflow on a never-true wait_condition does not
   yield a throwable Cancelled.** A bare future-cancellation surfaces a raw
   "was cancelled" string and fails the workflow task forever instead of routing
   to `CancelWorkflowExecution`. You must park on a durable
   `Temporalio::Workflow::sleep` timer, whose `await` raises a throwable
   `Temporalio::Exception::Cancelled`. *Surfaced by:* external-workflow (step 24).

6. **`try_cancel` activity on whole-workflow cancel emits an invalid command
   sequence.** Produced `[RequestCancelActivityTask, CancelWorkflowExecution,
   CancelWorkflowExecution]`, which core rejected, stalling the worker.
   *Surfaced by:* cancellation (step 5). *Workaround:* `cancellation_type =>
   'abandon'` (mirrors the SDK's own `AbandonCancelWorkflow` fixture).

7. **timer-vs-activity race via `Future->wait_any` emits cancel + double-complete
   -> worker SEGV on the timer-wins path.** *Surfaced by:* timer (step 4).
   *Workaround:* build the race with `on_ready` and leave the loser pending
   instead of `wait_any` (which cancels the loser).

8. **A true client `cancel` landing while an `:Update` handler is mid-flight does
   not surface a clean `WorkflowFailure`/`Cancelled`.** The worker dispatch raises
   a raw cancelled Future from `Runner.pm` ~2667; the run hangs ~183s. Related:
   signalling completion while an update is mid-flight (the genuine drain race)
   hung/segfaulted the live worker. *Surfaced by:*
   waiting-for-handlers-and-compensation (step 36) and waiting-for-handlers
   (step 35). *Workaround:* deterministic failing-node trigger; real cancel path
   proven offline.

## D. local activities (high)

9. **Live `execute_local_activity` segfaults the worker (exit 139)** — even for a
   plain, non-flaky activity. Isolated: an identical activity-retry smoke over a
   *normal* (non-local) activity is green, and the SDK's own local-activity
   coverage is replay-only. *Surfaced by:* local-activity (step 43); also why
   eager-workflow-start (step 44) gates its local-activity variant.

## E. Missing feature / gap (medium)

10. **Worker inbound interceptor chains are not runtime-invoked yet.** Only the
    client-outbound interceptor chain is wired today; worker inbound chains
    (workflow/activity inbound) are never called. *Surfaced by:*
    context-propagation (step 47). *Workaround:* the sample forwards context onto
    the activity call explicitly and proves the inbound read contract offline; the
    interceptor is written forward-compatible.

## Actionable fix: activity-choice unknown order hangs the workflow

This is the one place the full `just check` is red WITH the SDK present (the
offline/CI gate, no SDK, is green because the live smoke skips). The underlying
behavior is correct Temporal semantics (a non-ApplicationError exception is a
retryable workflow-TASK failure); the fix is to use the typed error in the
sample. A fixing agent can do this end to end.

**Symptom.** `activity-choice/lib/ActivityChoice/Menu.pm:49` calls a plain
`die "unknown beverage choice: ..."`. `Menu::resolve` runs inside the workflow
`:Run` at `activity-choice/lib/ActivityChoice/Workflow.pm:29`, so the `die`
becomes a *retryable workflow-task* failure: the task retries forever and a
caller's `$handle->result` never returns. The committed live smoke
`activity-choice/t/02-smoke.t` (test "unknown order fails the workflow") expects
a terminal `Temporalio::Exception::WorkflowFailure` and therefore times out
under the SDK.

**Files (in samples-perl, not sdk-perl):**
- `activity-choice/lib/ActivityChoice/Menu.pm` (the `die`)
- `activity-choice/lib/ActivityChoice/Workflow.pm` (the `:Run` caller)
- `activity-choice/t/01-*.t` (pure resolver test) and `t/02-smoke.t` (live)

**Fix (keep Menu.pm SDK-free; let the workflow own the Temporal failure):**
1. Change `Menu::resolve` to return `undef` for an unknown/empty choice instead
   of `die`, so it stays pure and offline-testable (no Temporalio dependency).
2. In `Workflow.pm`'s `:Run`, when `resolve` returns undef, raise
   `Temporalio::Exception::Application->throw(message => "unknown beverage
   choice: '$choice' ...", type => 'UnknownBeverage', non_retryable => 1)` so
   the workflow ends terminally Failed instead of retrying the task.
3. Update `t/01-*.t` to assert `resolve('nope')` returns undef (not that it dies).
4. `t/02-smoke.t` already expects a `WorkflowFailure`; confirm it now resolves
   fast (cause is the non-retryable `Application` error) rather than timing out.
5. Verify: offline `just check` stays green AND, with the SDK on `PERL5LIB`,
   `prove -l activity-choice/t/02-smoke.t` passes with no timeout.

**SDK-side (optional, lower priority).** Consider a clearer diagnostic when a
plain `die` in workflow code is converted to a retryable task failure, plus a
doc note that business/validation errors should be
`Temporalio::Exception::Application` (non-retryable where appropriate).

## Cross-cutting

Several of B, C, and the FD items may share a root cause in the workflow runner's
condition/teardown handling and the bridge's signal-FD lifecycle. Items 3 and 8
both cite `Runner.pm`. Worth looking at `_check_conditions` and the
cancel/teardown path together.

## F. Nexus serving disabled (high — found late, in the Nexus group)

11. **The worker hardcodes `enable_nexus => 0`, so it never polls Nexus tasks.**
    A handler worker therefore cannot serve Nexus operations: a workflow-run
    Nexus operation's backing workflow never runs, and a caller's
    `temporal workflow result` (or `$handle->result`) blocks forever. The full
    caller->handler round-trip is not serviceable in this SDK version.
    *Surfaced by:* nexus-hello (step 58); applies to nexus-messaging (59) and
    nexus-cancellation (60) too. *Workaround in samples:* prove the caller +
    handler operation bodies and the service registration offline against the
    real SDK classes; gate the live round-trip smoke to skip. Flip
    `enable_nexus` (and wire the Nexus task poller) to make live Nexus work.
