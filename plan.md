# sdk-perl Issue-Closeout Plan (I1-I14, I18)

TDD blueprint for the 15-issue closeout spec at `spec.md`.
Each step closes exactly one GitHub issue: it reproduces the defect (or asserts the missing capability) with a failing test first, then implements the minimal fix, so each commit lands green and the repro ships as permanent coverage.
Steps use the spec's issue IDs so `plan.md`, `todo.md`, `spec.md`, and the tracker stay 1:1; every landing commit carries `Closes #N`.
The R1-R97 cycle is archived at `.ai-sessions/r1-r97-remediation/`.

## Prime Directives

1. **Reproduce before fixing, inside each step.** No fix until a RED test fails for the documented reason. Reproduction and fix land in the same commit. Where a POD-only fix has no failing behavior to reproduce, the RED is replaced by an exercising assertion that pins the true shape (the R64 pattern), and the step is marked accordingly.
2. **Parity to Python source, verified at implementation time.** The GREEN checks the cited `../sdk-python` file, not memory.
3. **Replay over live where deterministic.** `sdk/t/replay/` for command-sequence and workflow-context behavior; `sdk/t/integration/` only for genuine live paths (they skip_all offline); crash/hang repros subprocess-guarded via `sdk/t/lib/SubprocessGuard.pm`; unit in `sdk/t/unit/`; POD in `sdk/xt/`.
4. **Every commit is green; test only your logic.** RED tests assert the fix's observable contract (emitted command, completion outcome, decoded field, typed error, interceptor invocation), never framework/library/language behavior.
5. **POD in the same change.** A behavior change updates POD in the same commit; `prove -lj4 xt` stays green.
6. **One attributed class per file.** Every new test fixture with a handler attribute lives one-per-file under `sdk/t/lib/` (the I18 constraint), even before I18 lands.
7. **Shim + memory guard.** Only I7 may touch `ext:`, and only if a pure-Perl framing change cannot carry the data. Any `ext:` change: `CARGO_BUILD_JOBS=2`, foreground, `cargo test`, cbindgen regen, Alien rebuild.

## Current Status

### Section 1: Silent-Failure Correctness Bugs
- [ ] I2 Fail the workflow task when a sync :Signal handler dies
- [ ] I3 Unwind Worker::run on a fatal poll-loop death
- [ ] I1 Settle an evicted async :Update parked on wait_condition without croaking
- [ ] I5 Make Test::Worker shutdown() raise on a wedged drain

### Section 2: Schedule Round-Trip Data Loss
- [ ] I4 Carry every _to_proto field through Schedule Action _from_proto

### Section 3: Small Parity Gaps
- [ ] I8 Accept result_type in start_update / execute_update
- [ ] I10 Validate Priority.priority_key at construction
- [ ] I13 Correct the count_workflows return-shape POD
- [ ] I11 Add WorkflowHandle fetch_history
- [ ] I9 Wire the dynamic update handler validator

### Section 4: Larger Parity Features
- [ ] I7 Fork-pool cancellation_details in children, then the heartbeat interceptor chain
- [ ] I6 OpenTelemetry workflow-outbound spans on the interceptor chain
- [ ] I12 Expose cloud, test, and health raw service handles

### Section 5: Cleanup and Upstream Canary
- [ ] I14 Deduplicate Duration conversion; re-verify the POSIX import (task)
- [ ] I18 Add the two-attributed-classes-per-file compile canary (task)

---

## Section 1: Silent-Failure Correctness Bugs

**Tools:**
- Skills: temporal:temporal-developer
- MCPs: mcp__temporal-docs__search_temporal_knowledge_sources
- Linters: none

### Step I2: Fail the Workflow Task When a Sync :Signal Handler Dies

**NOTE**: `Runner::_dispatch_signal` is at `sdk/lib/Temporalio/Workflow/Runner.pm:3164`; it wraps the handler in `Future->call` and, for a sync handler that dies, produces an already-failed future that is never tracked in `%in_progress_handlers` (declared :412, drained/observed at :2200-2202) and never observed. R11 built the die-to-failed-completion funnel in `sdk/lib/Temporalio/Worker/WorkflowDispatcher.pm` (commit dd83592). The async :Signal path already tracks its future in `%in_progress_handlers` (on_ready delete at :3203). Python fails the workflow task when a signal handler raises. New fixtures obey one-attributed-class-per-file (Directive 6).

```text
1. RED: Write a replay reproduction first:
   - Create sdk/t/lib/WfDef/DyingSignal.pm:
     - One workflow class (:isa(Temporalio::Workflow::Definition)), the ONLY attributed class in the file.
     - A :Run method that awaits Temporalio::Workflow::wait_condition on a flag that stays false (so the run parks and the signal is what drives the activation under test).
     - A synchronous :Signal handler (no await) that dies with a distinctive message: die "boom in sync signal\n".
   - Create sdk/t/replay/signal_handler_die.t:
     - Preamble: use v5.38; use warnings; use utf8; use Test2::V1;
     - Build a runner over the fixture (follow sdk/t/replay/signals.t for the harness) and drive an activation that delivers the signal to the dying sync handler.
     - Assert the produced WorkflowActivationCompletion is a FAILED completion (carries a failure), NOT a normal completion with commands.
     - Assert the failure message contains "boom in sync signal".
   - Run: ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lv t/replay/signal_handler_die.t ) and confirm it FAILS today (a normal completion is produced; the die is swallowed).

2. Verify the Python contract:
   - Read ../sdk-python for signal-handler exception handling (a raising signal handler fails the workflow task). Record the exact file:line in the test comments.

3. GREEN: Route the failed sync-signal future into the failed-completion funnel:
   - Edit sdk/lib/Temporalio/Workflow/Runner.pm _dispatch_signal (:3164): observe the Future->call result on the SYNC path so an immediate failure is not dropped. Funnel it to the same failed-WFT path R11 established in Worker/WorkflowDispatcher.pm (a die in the activation apply becomes a failed activation completion). The simplest faithful shape: track the sync-signal future in %in_progress_handlers exactly as the async arm does (:3196-3203) so the existing drain/observe at :2200-2202 sees its failure, OR raise the failure into the activation-apply catch that R11 funnels.
   - Do NOT alter query or update dispatch.

4. RED: Add the async-signal coverage assertion:
   - Create sdk/t/lib/WfDef/DyingAsyncSignal.pm (its own file, one attributed class): an async :Signal handler that awaits, then dies with "boom in async signal\n".
   - In signal_handler_die.t, add a case delivering to the async handler; assert it ALSO produces a FAILED WFT completion carrying the message.

5. GREEN: If step 4 is red, wire the async path minimally; if it already passes (the async future is tracked), record that in a comment and leave it.

6. REFACTOR: Collapse any duplicated failure-funnel logic between the sync and async signal arms so both settle through one sink; keep the R11 funnel as the single sink.

7. Update documentation:
   - Correct any signal-handler contract comment/POD in Runner.pm to state that a raising signal handler (sync or async) fails the workflow task.

8. Verify meaningful coverage of the signal-failure logic and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit message includes "Closes #2".
```

### Step I3: Unwind Worker::run on a Fatal Poll-Loop Death

**NOTE**: `Worker::run` is at `sdk/lib/Temporalio/Worker.pm:571`; the offending `await Future->wait_all(@loops)` is at :615. `on_fatal_error` is invoked near :631, `_initiate_shutdown_once` at :935, `_finalize_and_free` at :960 (idempotent). The R94 `on_fatal_error` hook fires only because its test initiates shutdown. Python parity: `../sdk-python` `worker/_worker.py:813` (FIRST_EXCEPTION wait) and `:846-848` (drain_poll_queue). This is a hang bug: prove it with a subprocess guard so a wedge cannot hang the suite. Read the existing on_fatal_error integration test for the exact fatal-injection hook before writing the repro.

```text
1. RED: Write the reproduction first, preferring a deterministic unit-level guard over a live test:
   - Create sdk/t/unit/fatal_poll_unwind.t:
     - Preamble: use v5.38; use warnings; use utf8; use Test2::V1;
     - Drive the loop-gather logic with SYNTHETIC loop futures: one that fails fatally and one or more that never resolve (the healthy siblings). Assert that the gather returns/settles on the FIRST failure within a bounded await rather than blocking on the never-resolving siblings. If run()'s gather is not separately callable, extract the gather into a private method in step 3 and test that method here; write the test against the intended method name now (it fails to compile/resolve today).
   - Additionally create sdk/t/integration/fatal_poll_unwind.t:
     - Preamble + sdk/t/lib/SubprocessGuard.pm; skip_all unless a worker can be constructed (match the existing integration skip pattern).
     - In the guarded child: build a worker, force ONE poll loop to die fatally (reuse the R94 on_fatal_error test's sentinel-to-failure technique), assert run() RETURNS (resolves or fails) within a bounded timeout carrying the injected error, and that finalize does not hang (the guard timeout is the failure signal).
   - Run both; confirm the unit guard FAILS today (blocks / never settles on first failure) and the integration test times out or skips.

2. Verify the Python contract:
   - Read ../sdk-python worker/_worker.py around :813 and :846-848; record in test comments how FIRST_EXCEPTION + drain_poll_queue compose.

3. GREEN: Replace the wait_all with a first-failure race plus drain:
   - Edit sdk/lib/Temporalio/Worker.pm run() (:571). Extract the loop gather into a private method (e.g. _await_loops_then_drain) and replace await Future->wait_all(@loops) at :615 with a first-failure race: complete normally when ALL loops drain on their ShutDown sentinel (clean path), but proceed to the fatal path as soon as ANY loop fails. Use wait_any over the loop futures for the failure signal composed with a wait_all for the clean drain, or the equivalent Future combinator.
   - On the fatal path: call _initiate_shutdown_once (:935) so core drains the outstanding polls (they resolve with the shutdown sentinel), await the loops' drain, THEN _finalize_and_free (:960), mirroring drain_poll_queue. Preserve the on_fatal_error invocation (:631) ordering: the hook fires with the fatal error before finalize.
   - Keep _finalize_and_free idempotent and the clean-path behavior unchanged.

4. RED: Add the healthy-path regression assertion:
   - In fatal_poll_unwind.t (unit guard), assert that with NO loop failing, the gather returns only after ALL loops drain (no premature return from the race).

5. GREEN: Tune the combinator so the clean path waits for all loops and the failure path returns on the first failure.

6. REFACTOR: Ensure run() reads as gather -> (fatal? initiate+drain) -> finalize via the extracted method.

7. Update documentation:
   - Correct the run() contract comment (around :565-608) to describe first-failure unwind and the poll drain before finalize.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - Commit includes "Closes #3".
```

### Step I1: Settle an Evicted Async :Update Parked on wait_condition Without Croaking

**NOTE**: `evict()` is at `sdk/lib/Temporalio/Workflow/Runner.pm:2169`; the conditions sweep is near :2020 and :3023 (each pending entry's future is a `_ConditionFuture` whose `->cancel` FAILS it, :1970/:3023). The handler's method future is a Future::AsyncAwait AWAIT_CLONE of that condition future. Handler-future sibling of the R8-R10 post-cancel cluster (commit f728d59). Nearest precedents: `sdk/t/replay/evict_pending_update.t`, `sdk/t/replay/repro_cancel_wait_condition.t`. Mechanism notes: `.ai-sessions/session-20260708-1748-goal-step-21-settle-cancelled-updates.md`.

```text
1. RED: Write the reproduction first:
   - Create sdk/t/lib/WfDef/UpdateParker.pm (one attributed class in the file):
     - An async :Update handler that awaits Temporalio::Workflow::wait_condition on a flag never set (the handler parks).
     - A :Run method that awaits its own never-satisfied wait_condition.
   - Create sdk/t/replay/evict_pending_update_wait_condition.t:
     - Test2::V1 preamble.
     - Drive: start the workflow, deliver a DoUpdate routing to the parked async handler (now parked on wait_condition), then deliver a RemoveFromCache (evict) activation.
     - Assert evict() completes AND the empty successful RemoveFromCache completion IS produced.
     - Assert NO die of the form /already failed and cannot be ->fail'ed/ occurs (wrap the drive in an eval and assert $@ is empty, or assert the eviction completion is emitted).
   - Run it; confirm it FAILS today (the croak fires, no eviction completion).

2. Verify the mechanism:
   - Re-read the R8-R10 cancel-fallback discrimination of AWAIT_CLONEd futures in Runner.pm and the session-20260708-1748 notes. Record in test comments which sweep double-settles the method future.

3. GREEN: Discriminate the handler-clone in the evict sweep:
   - Edit sdk/lib/Temporalio/Workflow/Runner.pm evict() (:2169) and its handler sweep / conditions sweep (:2020, :3023): sweep the parked condition future FIRST, or skip cancelling the AWAIT_CLONEd handler future when its underlying _ConditionFuture is present in the pending-conditions table, so exactly ONE settle reaches the method future (mirroring the R8-R10 discrimination).
   - Minimal change: do not alter the plain-future evict arm (R17 handles it) or non-update handler sweeps.

4. RED: Add a mixed-parking case:
   - Add a run with BOTH a plain-future-parked update (R17 path) AND a wait_condition-parked update, then evict. Assert both settle and the single eviction completion is produced.

5. GREEN: Ensure the discrimination handles both arms without double-settling either.

6. REFACTOR: Factor "is this future an AWAIT_CLONE of a tracked condition?" into a named helper if the R8-R10 site can share it.

7. Update documentation:
   - Correct the evict-path contract comment to note that condition-parked handler futures settle via their underlying condition, not a separate clone cancel.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - Commit includes "Closes #1".
```

### Step I5: Make Test::Worker shutdown() Raise on a Wedged Drain

**NOTE**: `Test/Worker.pm` `shutdown()` is at `sdk/lib/Temporalio/Test/Worker.pm:208`; it awaits `wait_any($run_future, $timeout_future)` with an UNSHIELDED run future (:210-211). The same file's run/await path already uses `$run_future->without_cancel` at :38 and branches on loser state at :48-51 (the b3facf7 pattern from R33/R46/R47). Test infra only, but it hides real worker hangs. Precedent: `sdk/t/unit/devserver_shutdown.t` (R46/R47 cases).

```text
1. RED: Write the wedge-detection test first:
   - Create sdk/t/unit/test_worker_shutdown.t:
     - Test2::V1 preamble.
     - Build a Temporalio::Test::Worker around a fake worker whose run future NEVER resolves (a stalled drain), using the loop/fixture style of t/unit/devserver_shutdown.t.
     - Call shutdown($short_timeout); assert it DIES with the "worker run did not drain within" diagnostic.
     - Clean case: a run future that resolves cleanly -> shutdown() returns without dying.
     - Failure case: a run future that fails -> shutdown() re-raises "worker run loop failed during shutdown".
   - Run it; confirm the wedge case FAILS today (shutdown() returns success), because wait_any cancels the loser so is_ready is true while is_failed is false.

2. Verify the loser-state semantics:
   - Record in test comments: wait_any cancels the losing future; a cancelled Future is ready-but-not-done-and-not-failed; without_cancel shields it so the real state survives.

3. GREEN: Shield the run future in the race and branch on the real loser state:
   - Edit sdk/lib/Temporalio/Test/Worker.pm shutdown() (:208): await Future->wait_any($run_future->without_cancel, $loop->timeout_future(after => $timeout)); then branch on the ACTUAL run-future state: not ready (timeout won) -> die "worker run did not drain within ${timeout}s"; failed -> re-raise "worker run loop failed during shutdown: ..."; else return. Match the run-path shape at :36-51.

4. RED: Add a "diagnostic is reachable" assertion:
   - Assert the wedge case's die message is exactly the drain-timeout diagnostic (not the loop-failed one), proving the branch is reached and not dead code.

5. GREEN: Order the branch so timeout and failure produce distinct messages.

6. REFACTOR: If run() (:24) and shutdown() (:208) now share the without_cancel-race-then-branch shape, extract a private helper both call.

7. Update documentation:
   - Update the shutdown() contract comment (:205-207) to state it raises on a wedged drain within the timeout.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - Commit includes "Closes #5".
```

---

## Section 2: Schedule Round-Trip Data Loss

**Tools:**
- Skills: temporal:temporal-developer
- MCPs: mcp__temporal-docs__search_temporal_knowledge_sources
- Linters: none

### Step I4: Carry Every _to_proto Field Through Schedule Action _from_proto

**NOTE**: `Schedule::Action::StartWorkflow::_to_proto` is at `sdk/lib/Temporalio/Schedule/Action.pm:77` and writes task_timeout, retry_policy (:107), memo, search_attributes (:118-120), headers, priority, and user_metadata (static_summary/static_details, :129-131). `_from_proto` is at :142 and drops most of them; it keeps input Payloads raw (:141). Python preserves user_metadata as a raw Payload through the round trip (`../sdk-python` `client/_schedule.py` ~:551-552). R82 added the encode side (commit 8d37317).

```text
1. RED: Write the round-trip reproduction first:
   - Create sdk/t/unit/schedule_action_roundtrip.t:
     - Test2::V1 preamble.
     - Build a Temporalio::Schedule::Action::StartWorkflow with EVERY optional field populated: workflow/run/task/execution timeouts, retry_policy, memo, search_attributes, headers, priority, static_summary, static_details.
     - Encode via _to_proto (await; provide a minimal fake client/data_converter as the existing schedule tests do), then rebuild via _from_proto on the resulting NewWorkflowExecutionInfo.
     - Assert the rebuilt action's accessors return every populated field (static_summary/static_details as pass-through Payloads, timeouts in seconds, retry_policy, memo, search_attributes, headers, priority).
   - Run it; confirm it FAILS today (fields come back undef).

2. Verify the Python contract:
   - Read ../sdk-python client/_schedule.py _from_proto / _to_proto ~:551-552; confirm user_metadata round-trips as a raw Payload. Record file:line in test comments.

3. GREEN: Complete _from_proto:
   - Edit sdk/lib/Temporalio/Schedule/Action.pm _from_proto (:142) to decode every field _to_proto writes: user_metadata -> static_summary/static_details (raw Payload pass-through), plus workflow/run/task timeouts, retry_policy, memo, search_attributes, headers, priority.
   - Mirror the decode conventions the module already uses for these proto shapes; keep input Payloads raw (the :141 contract).

4. RED: Add a describe-modify-update integration assertion:
   - Create sdk/t/integration/schedule_static_summary_roundtrip.t: skip_all without a dev server. Create a schedule with static_summary, describe, update, describe again; assert static_summary survives the describe-modify-update cycle.

5. GREEN: The unit fix should satisfy the integration path; if the integration test reveals another dropped field, extend _from_proto.

6. REFACTOR: If _to_proto and _from_proto now share a field list that can drift, add a single shared list of the optional field names both iterate, so a future field decodes automatically.

7. Update documentation:
   - Confirm the POD at :186-206 lists every round-tripped field; correct it if the decode set changed.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #4".
```

---

## Section 3: Small Parity Gaps

**Tools:**
- Skills: temporal:temporal-developer
- MCPs: mcp__temporal-docs__search_temporal_knowledge_sources
- Linters: none

### Step I8: Accept result_type in start_update / execute_update

**NOTE**: `start_update` is at `sdk/lib/Temporalio/Client/WorkflowHandle.pm:488`, `execute_update` at :475 (delegates to start_update), the shared `_update_handle` at :595. `get_update_handle` (:577) already accepts and threads `result_type` (known-options map at :580 lists `result_type => 1`; passes it at :584-586). R92 added get_update_handle (commit 4412c1e). Prefer a UNIT test faking the update RPC so the decode-hint assertion is deterministic and offline.

```text
1. RED: Write the decode-hint test first:
   - Create sdk/t/unit/start_update_result_type.t (fake the update RPC the way other WorkflowHandle unit tests fake the connection):
     - Assert start_update(..., result_type => <TypeName>) constructs a WorkflowUpdateHandle carrying that result_type as its first-payload decode hint (inspect the handle's decode hint as get_update_handle's test does).
     - Assert execute_update(..., result_type => ...) threads the same hint.
   - Run it; confirm it FAILS today (start_update rejects the unknown option via the R44 validator, or never sets the hint).

2. Verify the Python contract:
   - Confirm ../sdk-python start_update takes result_type as a decode hint (client/_workflow.py start_update). Record file:line in test comments.

3. GREEN: Thread result_type through:
   - Edit sdk/lib/Temporalio/Client/WorkflowHandle.pm start_update (:488): add result_type to its known-options list (so the R44 validator admits it) and pass it into _update_handle (:595) as the decode hint, exactly as get_update_handle does at :584-586.
   - execute_update (:475) delegates; confirm the option flows through and add it to its known-options list if it validates separately.

4. RED: Add a strictness assertion:
   - Assert an UNKNOWN option to start_update still raises the R44 typed argument error (result_type now known; a typo still rejected).

5. GREEN: Ensure only result_type joined the known set; nothing else loosened.

6. REFACTOR: If start_update, execute_update, and get_update_handle share a known-options list, centralize result_type there.

7. Update documentation:
   - Add result_type to the start_update / execute_update POD as the update-result decode hint.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #8".
```

### Step I10: Validate Priority.priority_key at Construction

**NOTE**: `Common/Priority.pm` ADJUST is at :26 and validates only fairness_weight (:33-35) with a Scalar::Util::looks_like_number guard. priority_key (:16) is unvalidated despite the comment at :28 citing the guard. Python rejects a non-integer or sub-1 priority_key in Priority `__post_init__` (`../sdk-python` `common.py` ~:1222-1228). `sdk/t/unit/priority_fairness.t` exists.

```text
1. RED: Write the rejection tests first:
   - Extend sdk/t/unit/priority_fairness.t:
     - Assert Temporalio::Common::Priority->new(priority_key => 0) throws Temporalio::Exception::Argument.
     - Assert priority_key => -1 throws.
     - Assert priority_key => 2.5 (non-integer) throws.
     - Assert priority_key => "high" (non-number) throws.
     - Assert priority_key => 3 and priority_key => undef are ACCEPTED.
   - Run it; confirm the rejection cases FAIL today (no throw).

2. Verify the Python contract:
   - Read ../sdk-python common.py Priority __post_init__ (~:1222-1228); confirm the >=1 integer rule. Record file:line in test comments.

3. GREEN: Add the ADJUST guard:
   - Edit sdk/lib/Temporalio/Common/Priority.pm ADJUST (:26): when priority_key is defined, require a positive integer (>= 1), else throw Temporalio::Exception::Argument with a message naming priority_key. Use the fairness_weight guard's looks_like_number style plus an integer check (e.g. int($k) == $k).

4. RED: (covered by step 1's accept/reject matrix; no separate integration test.)

5. GREEN: (n/a — pure construction guard.)

6. REFACTOR: Inline the check, or a small local sub if it would be reused.

7. Update documentation:
   - Update the priority_key POD / field comment (:14-16) to state the >=1-integer construction constraint.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #10".
```

### Step I13: Correct the count_workflows Return-Shape POD

**NOTE**: `count_workflows` returns `{ count => N, groups => [...] }` (`sdk/lib/Temporalio/Client.pm:298-300`), but the POD at :1226 says it resolves "to the count". This is a POD fix backed by an exercising shape assertion (the R64 pattern, Directive 1): the assertion is green against code from the start and guards the shape the POD documents. There is no failing behavior to reproduce.

```text
1. Pin the shape with an exercising assertion:
   - Create sdk/t/unit/count_workflows_shape.t (or extend an existing client unit test): drive count_workflows with a fake connection returning a CountWorkflowExecutionsResponse (match how other client unit tests fake the RPC).
   - Assert the resolved value is a HASH ref with a `count` key and a `groups` key.
   - Assert the group-by form populates `groups` with the aggregation buckets.
   - This assertion is GREEN against the code immediately; its job is to lock the shape the POD must describe (not to fail first).

2. Verify the Python contract:
   - Confirm ../sdk-python CountWorkflowsResponse handling (count plus groups). Record file:line in test comments.

3. Correct the POD:
   - Edit sdk/lib/Temporalio/Client.pm =head2 count_workflows (:1226): document the { count, groups } return shape with a short example for the plain form (read $result->{count}) and the group-by form (iterate $result->{groups}).

4. (n/a — the shape assertion in step 1 is the exercising test.)

5. (n/a.)

6. REFACTOR: none.

7. Update documentation:
   - This step IS the doc fix; keep prove -lj4 xt (POD syntax/coverage) green.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #13".
```

### Step I11: Add WorkflowHandle fetch_history

**NOTE**: `fetch_history_events` is at `sdk/lib/Temporalio/Client/WorkflowHandle.pm:609` (async iterator, ALL_EVENT, no waiting). `Temporalio::Client::WorkflowHistory` exists with from_json/to_json (`sdk/lib/Temporalio/Client/WorkflowHistory.pm`). Python's WorkflowHandle.fetch_history is at `../sdk-python` `client/_workflow.py:391` and returns a WorkflowHistory. Replay entry: `Test::WorkflowReplay::replay_workflow` (see sdk/t/replay/history_replayer.t).

```text
1. RED: Write the fetch-then-replay test first:
   - Create sdk/t/unit/fetch_history.t:
     - Fake the fetch_history_events iterator to yield a known event list (reuse the fixture history from sdk/t/replay/history_replayer.t).
     - Assert fetch_history returns a Temporalio::Client::WorkflowHistory whose workflow_id and events match.
     - Assert that history replays through Test::WorkflowReplay::replay_workflow identically to a WorkflowHistory->from_json load of the same events.
   - Run it; confirm it FAILS today (no fetch_history method).

2. Verify the Python contract:
   - Read ../sdk-python client/_workflow.py:391; confirm fetch_history assembles a WorkflowHistory from the fetched events. Record file:line in test comments.

3. GREEN: Add fetch_history:
   - Edit sdk/lib/Temporalio/Client/WorkflowHandle.pm: add async method fetch_history(%opts) that drains fetch_history_events (:609) into an events arrayref and returns Temporalio::Client::WorkflowHistory->new(workflow_id => $self->id, events => \@events). Pass through the same %opts fetch_history_events accepts.

4. RED: Add an equivalence assertion:
   - Assert fetch_history's WorkflowHistory->to_json equals from_json(...)->to_json for the same events (round-trip parity with the R95 class).

5. GREEN: Ensure the assembled history uses the field names the WorkflowHistory class expects.

6. REFACTOR: Keep fetch_history a thin assembler over fetch_history_events.

7. Update documentation:
   - Add a =head2 fetch_history POD entry describing the return type and its relationship to fetch_history_events.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #11".
```

### Step I9: Wire the Dynamic Update Handler Validator

**NOTE**: `workflow_set_update_handler` (`sdk/lib/Temporalio/Workflow/Runner.pm:3392`) stores a validator only for NAMED updates (:3402-3404); the comment at :3389 says "a validator passed with a dynamic install is ignored". Validation dispatch is `_apply_do_update` step 3 (~:3438). Python falls back to the dynamic definition's validator (`../sdk-python` `_workflow_ops.py` workflow_get_update_validator). Unified handler tables are the R86 `{updates}/{validators}/{dynamic}` structure. The read-only guard: a validator throw -> single UpdateResponse.rejected; a command-emitting validator -> workflow TASK failure.

```text
1. RED: Write the dynamic-validator replay test first:
   - Create sdk/t/lib/WfDef/DynUpdateValidator.pm (one attributed class in the file):
     - In :Init or :Run, call Temporalio::Workflow::set_dynamic_update_handler with a handler and a validator coderef that REJECTS on a sentinel argument (die a Temporal failure) and admits otherwise.
   - Create sdk/t/replay/dynamic_update_validator.t:
     - Test2::V1 preamble.
     - Drive a DoUpdate (run_validator true) with a name routing to the dynamic handler and the rejecting sentinel; assert an UpdateResponse.rejected is emitted and the handler did NOT execute (no acceptance, no result command).
     - Drive a second DoUpdate with an admitted argument; assert UpdateResponse.accepted then completed.
   - Run it; confirm the rejecting case FAILS today (accept-then-execute because the dynamic validator is ignored).

2. Verify the Python contract:
   - Read ../sdk-python _workflow_ops.py for workflow_get_update_validator's fallback to the dynamic definition's validator. Record file:line in test comments.

3. GREEN: Wire the dynamic validator fallback:
   - Edit sdk/lib/Temporalio/Workflow/Runner.pm:
     - In workflow_set_update_handler (:3392) / the runtime handler tables, store the validator when a DYNAMIC update handler is installed with one (so the dynamic definition can carry a validator), matching Python.
     - In _apply_do_update step 3 (~:3438): when the NAMED validator lookup misses AND the update routed to the dynamic handler, fall back to the dynamic definition's validator. Run it under the SAME read-only guard as a named validator (throw -> single rejection; command emission -> workflow TASK failure).

4. RED: Add a read-only-violation assertion:
   - Add a fixture (its own file) whose dynamic validator issues a command; assert it produces a workflow TASK failure, matching the named-validator read-only guard.

5. GREEN: Route the dynamic validator through the same read-only guard so the violation path matches.

6. REFACTOR: If named and dynamic validator resolution can share one "resolve the validator for this update" helper, extract it (mirrors Python's workflow_get_update_validator).

7. Update documentation:
   - Correct the :3389 comment and the set_dynamic_update_handler POD to state the dynamic validator is now honored.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #9".
```

---

## Section 4: Larger Parity Features

**Tools:**
- Skills: temporal:temporal-developer
- MCPs: mcp__temporal-docs__search_temporal_knowledge_sources
- Linters: none

### Step I7: Fork-Pool cancellation_details in Children, Then the Heartbeat Interceptor Chain

**NOTE**: One issue (#7), two capabilities on the same pool control channel (`sdk/lib/Temporalio/Activity/Pool.pm`, fork channel built R4/R18/R19). The ActivityOutbound chain is in `sdk/lib/Temporalio/Worker/ActivityDispatcher.pm`; the activity context is `sdk/lib/Temporalio/Activity/Context.pm`. This step is sequenced deliberately: land the SIMPLER parent-to-child direction first (cancellation_details, no interceptor chain), then the harder child-to-parent heartbeat relay. Today the pool relays already-serialized ActivityHeartbeat bytes (nothing chain-shaped parent-side) and the cancellation-details holder does not cross the fork. Prefer a pure-Perl framing change; only touch `ext:` if the channel frame genuinely cannot carry structured data, and then follow Directive 7. Precedent tests: sdk/t/unit/activity_cancellation_details.t, activity_worker_shutdown.t, activity_inbound_headers.t, activity_pool.t.

```text
1. RED (direction A, parent-to-child cancellation_details): Write the reproduction first:
   - Create sdk/t/lib/ActDef/PoolCancelDetails.pm (one activity class in the file): a sync (fork-pool) activity that, on cancel, records ctx->cancellation_details and whether the distinct worker-shutdown event fired.
   - Create sdk/t/integration/pool_cancellation_details.t (skip_all without a server), OR a unit-level pool harness test if the fork channel can be driven offline (follow activity_pool.t's harness):
     - Cancel a running pooled activity with a reason (e.g. paused, then separately worker_shutdown); assert the child's ctx->cancellation_details is populated with the reason flags and the worker-shutdown event fires in the child.
   - Run it; confirm it FAILS today (cancellation_details is undef in the child).

2. Verify the Python contract:
   - Read ../sdk-python for cancellation-details delivery to activities and the worker-shutdown event. Record file:line in test comments.

3. GREEN (direction A): Forward cancellation reason/details parent-to-child:
   - Edit sdk/lib/Temporalio/Activity/Pool.pm + sdk/lib/Temporalio/Activity/Context.pm: forward the cancellation reason and details alongside the existing cancel delivery so the child context populates cancellation_details and the worker-shutdown event. Prefer extending the existing cancel frame in pure Perl.
   - Add a parity assertion: pooled cancellation_details match what an async activity sees for the same reason (reuse activity_cancellation_details.t's expectations).

4. RED (direction B, child-to-parent heartbeat interceptor chain): Write the reproduction:
   - Create sdk/t/lib/ActDef/PoolHeartbeatIntercepted.pm (one activity class): a sync activity that heartbeats with structured details.
   - Create sdk/t/integration/pool_heartbeat_interceptor.t (or unit harness): register an ActivityOutbound interceptor recording observed heartbeats; run the activity in the fork pool; assert the interceptor OBSERVED the heartbeat with STRUCTURED details (not opaque bytes).
   - Run it; confirm it FAILS today (the interceptor sees nothing / only serialized bytes).

5. GREEN (direction B): Relay structured heartbeat details child-to-parent:
   - Edit sdk/lib/Temporalio/Activity/Pool.pm + sdk/lib/Temporalio/Worker/ActivityDispatcher.pm: relay Perl-level heartbeat details (not pre-serialized bytes) up the channel so the PARENT runs the ActivityOutbound chain before forwarding the heartbeat to core.
   - If, and only if, the channel frame cannot carry structured data in pure Perl, follow Directive 7: edit ext/temporalio-perl-bridge/src/lib.rs, run ( cd ext/temporalio-perl-bridge && CARGO_BUILD_JOBS=2 cargo test ) foreground, regenerate the cbindgen header, rebuild the installed Alien::Temporalio::PerlBridge.

6. REFACTOR: Unify the heartbeat relay so async and pooled activities traverse the same ActivityOutbound chain code (one parent-side entry point).

7. Update documentation:
   - Remove or update the §0-deviation notes in Pool.pm / Context.pm; state that pooled activities now receive cancellation details and run the heartbeat chain.

8. Verify and run the repo gate (plus shim gates only if ext: changed):
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - If ext: changed: ( cd ext/temporalio-perl-bridge && CARGO_BUILD_JOBS=2 cargo test ) and the Alien rebuild, all foreground under the memory guard.
   - Commit includes "Closes #7".
```

### Step I6: OpenTelemetry Workflow-Outbound Spans on the Interceptor Chain

**NOTE**: The interceptor is `sdk/lib/Temporalio/Contrib/OpenTelemetry/TracingInterceptor.pm`; it carries seam comments at init() and the `%OUT_SPAN_VERB` table, and traces client/WFT/activity paths (R22) but not workflow-outbound ops. The R71 workflow-outbound chain exists. Header injection uses the pass-through Payload contract in `Temporalio::Interceptor::Headers`. Python reference: `../sdk-python` `contrib/opentelemetry.py` `_TracingWorkflowOutboundInterceptor` (~:751-831). Fake tracer: `sdk/t/lib/FakeOTel.pm`; existing test: `sdk/t/unit/tracing.t`.

```text
1. RED: Write outbound-span tests first:
   - Extend sdk/t/unit/tracing.t (using sdk/t/lib/FakeOTel.pm):
     - For each outbound op (execute_activity, start_child_workflow, signal_child_workflow, signal_external_workflow, start_nexus_operation): assert a span named per %OUT_SPAN_VERB is created when the op runs on the outbound chain, and the trace context is INJECTED into the op's headers (assert the header payload the interceptor added).
     - Assert span creation NO-OPS during replay (drive the interceptor in a replaying activation; assert no span is created).
   - Run it; confirm it FAILS today (no outbound spans, no header injection).

2. Verify the Python contract:
   - Read ../sdk-python contrib/opentelemetry.py _TracingWorkflowOutboundInterceptor (~:751-831); record span names and the header-injection mechanism in test comments.

3. GREEN: Implement the outbound tracing wrapper:
   - Edit sdk/lib/Temporalio/Contrib/OpenTelemetry/TracingInterceptor.pm: at the R71 seam, wrap each outbound op in a span named per %OUT_SPAN_VERB and inject the current trace context into the op's headers via the Temporalio::Interceptor::Headers pass-through Payload contract.
   - Guard span creation to no-op during replay (reuse the interceptor's existing replay check used by the inbound side).

4. RED: Add a context-propagation assertion:
   - Assert the injected header round-trips: a downstream inbound interceptor reading the header sees the parent span context (reuse FakeOTel to assert parent/child linkage).

5. GREEN: Ensure the injected context uses the same header key the inbound side reads.

6. REFACTOR: Factor the per-op span+inject into one helper keyed by %OUT_SPAN_VERB so adding an op is a table entry.

7. Update documentation:
   - Drop the pending/deferred note in the TracingInterceptor POD; document that workflow-outbound ops are now traced and replay-safe.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #6".
```

### Step I12: Expose cloud, test, and health Raw Service Handles

**NOTE**: `Client.pm` exposes only `workflow_service` (:94) and `operator_service` (:95). `Client/RawService.pm` generates a handle from any vendored service descriptor; `Connection::rpc_call` takes a `service =>` discriminator. The vendored protos under `sdk/share/proto/temporal/api/` include workflowservice and operatorservice but NOT cloud, test, or health. Descriptor roots register in `sdk/lib/Temporalio/Core/Proto.pm`. Confirm the c-bridge service discriminator values against the pinned header (`../sdk-rust/crates/sdk-core-c-bridge/include/temporal-sdk-core-c-bridge.h`). RED leads: the accessor test fails today because there is no accessor and no descriptor; vendoring the protos is part of GREEN.

```text
1. RED: Write the accessor shape tests first:
   - Create sdk/t/unit/raw_service_extra.t:
     - Assert $client->cloud_service, $client->test_service, and $client->health_service each return a handle object.
     - Assert each handle exposes at least one expected snake_case rpc method for that service (confirm exact rpc names from the vendored descriptor in step 3; candidates: health_service->check, test_service->lock_time_skipping / unlock_time_skipping, a known CloudService rpc).
     - No live RPC: assert method existence / can, not a call result.
   - Run it; confirm it FAILS today (no accessors; descriptors not loaded).

2. Verify the Python surface and the discriminator:
   - Confirm ../sdk-python exposes cloud/test/health service objects (client _client.py service accessors). Confirm each service's c-bridge discriminator value against ../sdk-rust/crates/sdk-core-c-bridge/include/temporal-sdk-core-c-bridge.h. Record both in test comments.

3. GREEN: Vendor protos, register descriptors, add accessors:
   - Vendor the cloud, test, and health service protos at the pinned sdk-rust tag into sdk/share/proto/ (locate them under ../sdk-rust/crates/.../protos or the sdk-python/sdk-ruby vendored trees; match the pinned tag).
   - Edit sdk/lib/Temporalio/Core/Proto.pm: add one descriptor root per newly vendored service so RawService can read them.
   - Edit sdk/lib/Temporalio/Client.pm: add cloud_service / test_service / health_service accessors, each building a RawService handle with the correct service discriminator (mirror workflow_service :94 / operator_service :95), threading the Connection.
   - Ensure Connection::rpc_call's service discriminator accepts the new values (confirmed against the header in step 2).

4. RED: Add a method-map assertion:
   - Assert each generated handle's method map is non-empty and snake_case (the RawService descriptor-driven contract), so a mis-registered descriptor is caught.

5. GREEN: Fix any descriptor root path so the method map generates.

6. REFACTOR: If the three accessors are structurally identical, factor a shared builder keyed by service name/discriminator.

7. Update documentation:
   - Update the Client.pm raw-service POD (:1058, :1347-1390) to list cloud_service, test_service, health_service alongside workflow_service and operator_service.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit includes "Closes #12".
```

---

## Section 5: Cleanup and Upstream Canary

**Tools:** none

### Step I14: Deduplicate Duration Conversion; Re-Verify the POSIX Import (task)

**NOTE**: The R74 pair `_duration_from_seconds`/`_seconds_from_duration` is at `sdk/lib/Temporalio/Converter/Failure.pm:97/:103`. Copies live in `sdk/lib/Temporalio/Common/RetryPolicy.pm` (~:29-56), `sdk/lib/Temporalio/Workflow/Commands.pm`, and the Schedule modules. IMPORTANT: the issue's "unused POSIX import" claim is STALE. `POSIX::close` is called at `sdk/lib/Temporalio/Activity/Pool.pm:499`, so the import is live. Pure refactor, behavior pinned by existing suites.

```text
1. Scope:
   - Artifact(s): sdk/lib/Temporalio/Core/Proto.pm (or a new sdk/lib/Temporalio/Common/Duration.pm), sdk/lib/Temporalio/Converter/Failure.pm, sdk/lib/Temporalio/Common/RetryPolicy.pm, sdk/lib/Temporalio/Workflow/Commands.pm, sdk/lib/Temporalio/Schedule/*.pm, sdk/lib/Temporalio/Activity/Pool.pm.
   - Desired end state: one shared seconds<->google.protobuf.Duration conversion pair; every call site points at it; no behavior change; suites green. The POSIX import in Pool.pm is confirmed live and left in place (that half of #14 closed as not-applicable).

2. Tooling:
   - Skills: none
   - MCPs: none
   - External: grep for the duplicated conversions before and after.

3. Do the work:
   - Verify POSIX is used: run `grep -n 'POSIX::' sdk/lib/Temporalio/Activity/Pool.pm`. If any POSIX:: call is present (it is, at :499), KEEP `use POSIX ()`. Only remove the import if grep shows zero POSIX:: uses.
   - Choose the shared home: add the conversion pair to sdk/lib/Temporalio/Core/Proto.pm (the R74 executor's suggested home) as helpers, e.g. duration_from_seconds / seconds_from_duration, with the EXACT semantics of the Converter/Failure.pm pair (fractional seconds split into Duration seconds + nanos; undef -> unset).
   - Point every call site at the shared pair: replace the local definitions in Converter/Failure.pm (:97/:103), Common/RetryPolicy.pm, Workflow/Commands.pm, and the Schedule modules with calls to the shared helpers. Keep each call site's surrounding behavior identical.
   - Do NOT change any public method signature or return value.

4. Verify:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t ) exits 0 (the RetryPolicy, Failure-converter, Commands, and Schedule suites pin the behavior).
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt ) exits 0.
   - `grep -rn 'sub _duration_from_seconds\|sub _seconds_from_duration\|split.*Duration' sdk/lib` shows the conversion defined in exactly one place.

5. Document:
   - Add a one-line POD/comment on the shared helpers naming the four former call sites. Commit message includes "Closes #14" and notes the POSIX half was not-applicable (import live at Pool.pm:499).
```

### Step I18: Add the Two-Attributed-Classes-Per-File Compile Canary (task)

**NOTE**: Upstream perl 5.38+/Future::AsyncAwait parser-state bug (`.ai-sessions/lessons.md`, entries 2026-07-09 and 2026-07-10). The SDK routes around it (one attributed class per file). No SDK-side fix; this adds a TODO/xfail canary that flips to passing when upstream fixes the parser, plus an upstream-report note. `sdk/t/unit/attribute_handlers.t` exists.

```text
1. Scope:
   - Artifact(s): sdk/t/unit/attribute_handlers.t (add a TODO test), an upstream-report note draft (in the commit body).
   - Desired end state: the suite stays green with a TODO-marked test asserting two attributed :isa classes in one file SHOULD compile; when a future toolchain fixes the parser it flips to an unexpected pass and flags the workaround can be relaxed.

2. Tooling:
   - Skills: none
   - MCPs: none
   - External: none.

3. Do the work:
   - Add to sdk/t/unit/attribute_handlers.t a Test2::V1 todo block named clearly, e.g. "TODO(#18): two attributed :isa classes per file should compile once upstream perl/F::AA fixes the parser state".
   - Inside it, eval-string compile two attributed classes in one unit with Future::AsyncAwait loaded (the #18 minimal repro):
       require Future::AsyncAwait and Temporalio::Workflow::Definition first, then:
       my $ok = eval q{ use feature 'class'; no warnings 'experimental::class'; class TwoA::X :isa(Temporalio::Workflow::Definition) { method run :Run('X') ($i) { return $i } } class TwoA::Y :isa(Temporalio::Workflow::Definition) { method run :Run('Y') ($i) { return $i } } 1; };
     - Assert (inside the TODO) that $ok is true and $@ is empty. It is expected to FAIL today (the eval dies with /attributes must come before the signature/); the TODO marker keeps the suite green.
   - Add a comment above the block pointing at .ai-sessions/lessons.md (2026-07-09 / 2026-07-10 entries) and GitHub issue #18, stating that an unexpected PASS means the one-attributed-class-per-file workaround can be revisited.

4. Verify:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lv t/unit/attribute_handlers.t ) exits 0 with the new test reported as TODO (not a hard failure).
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t ) exits 0 overall.

5. Document:
   - The README already documents the one-attributed-class-per-file rule. Leave a one-paragraph upstream-report draft (minimal repro + environment) in the commit body for the human to file. Commit message includes "Closes #18".
```

---

## Section 6: Frontier Review Remediation

**Tools:**
- Skills: temporal:temporal-developer
- MCPs: mcp__temporal-docs__search_temporal_knowledge_sources
- Linters: none

Fifteen steps, one per reviewed commit, blocks first. Spec: `spec.md` "Frontier Review Remediation (F1-F15)". Every step: reproduce first (a RED test that fails on HEAD), Python parity from `../sdk-python` source, no em-dashes or en-dashes on any added line, FINAL line anchors or none, one attributed class per file, `Syntax::Keyword::Dynamically` not `local` across awaits, Test2::V1 preamble with `T2->` calls only. Line numbers below are approximate anchors from the review; re-locate before editing.

### Step F1: Make OTel Outbound Headers Real Payloads End to End

**NOTE**: Block from the I6 review. `TracingInterceptor.pm` `_carrier_to_payload` (~83-90) returns an unblessed hashref; `Interceptor/Headers.pm` `is_payload` (~32) requires a blessed Payload, so every Runner root (`_root_schedule_activity` ~812, local ~957, child ~1258, signal roots ~1376/~1490, `_root_continue_as_new` ~1783) double-encodes it; `_payload_to_carrier` (~96) requires `ref eq 'HASH'` so blessed wire Payloads from `ActivityDispatcher.pm` (~233) extract nothing. lessons.md 2026-06-26 records this exact double-encode class. Python builds a real Payload via `payload_converter.to_payloads` (`_interceptor.py:675-682`).

```text
1. RED: Write end-to-end tests first:
   - Extend sdk/t/unit/tracing.t:
     - Drive a workflow that calls execute_activity through the real Runner via the replay harness (see t/replay for the pattern lessons.md 2026-06-26 prescribes), decode the emitted ScheduleActivity.headers ONCE with the data converter, and assert the recovered carrier's traceparent equals the outbound span's traceparent.
     - Feed a BLESSED wire Payload (Temporalio::Payload or a decoded proto Payload) carrying a carrier into intercept_activity and assert the activity span's parent is the outbound span.
     - For execute_local_activity, start_child_workflow, signal_child_workflow, signal_external_workflow: assert the injected header round-trips to THAT op's span traceparent (today only execute_activity does).
     - A pre-existing _tracer-data header is replaced, not duplicated.
     - Parent-missing gate: after execute_workflow with no start header and always_create_workflow_spans=0, an outbound op creates no span and injects nothing; with always_create_workflow_spans=1 it does both; continue_as_new injects nothing when the carrier is absent.
   - Run; confirm the replay-harness and blessed-Payload cases FAIL today.

2. Verify the Python contract: _context_carrier_to_headers (_interceptor.py:675-682) produces a Payload via the payload converter; record in test comments.

3. GREEN: Fix the representation:
   - _carrier_to_payload returns a blessed Temporalio::Payload (or the class _payload_class() in Interceptor/Headers.pm resolves to) with metadata { encoding => 'json/plain' } and the JSON data; confirm is_payload accepts it.
   - _payload_to_carrier duck-types on can('metadata') and can('data') (Payload.pm POD says converters must duck-type), accepting both blessed and legacy hashref shapes.

4. RED: Add a regression test that to_payload_map on a header map containing the injected payload passes it through unchanged (no double encode), using the Headers.pm contract directly.

5. GREEN: Adjust if needed so the pass-through holds.

6. REFACTOR: One helper builds the header payload for both the client outbound and workflow outbound sides; drop any duplicate.

7. Update documentation: TracingInterceptor.pm POD states headers are Payloads and survive the wire; note the parent-missing gate on the outbound side.

8. Verify and run the repo gate:
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )
   - ( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )
   - Commit references "Refs #6" (the issue is closed; do not reopen it from the commit).
```

### Step F2: Route Signal-Handler Failures Through the Body's Full Classification

**NOTE**: Block from the I2 review, a regression. `Runner.pm` `_settle_signal` (~3211) implements only the workflow-failure versus task-failure split of `_outcome_for_failure` (~4079-4131). Cancel fails parked futures with `Temporalio::Exception::Cancelled` (~1318, ~1709, ~1739, ~2962), which `_is_workflow_failure_exception` accepts, so a parked async :Signal handler claims `_emit_terminal_command` (~3978) with FailWorkflowExecution before the body's Cancel branch (~4094-4103) runs. Python: `_run_top_level_workflow_function` (`_workflow_instance.py:2518-2565`) orders deleting, continue-as-new, cancel-requested, then the two-way split, for body and handlers alike. Also: thirteen em-dashes on I2's added lines (Runner.pm ~3164, ~3165, ~3172, ~3255; the three fixtures; the .t header).

```text
1. RED: Write classification tests first:
   - Extend sdk/t/replay/ (new file signal_handler_classification.t or the I2 file):
     - cancel_workflow while an async :Signal handler is parked on sleep: the completion carries exactly ONE cancel_workflow_execution and no fail_workflow_execution.
     - continue_as_new raised from inside a :Signal handler produces continue_as_new_workflow_execution, not a task failure.
     - an async :Signal handler that throws a Temporal ApplicationError (non-benign) fails the execution with that type (the fourth cell the I2 commit claimed).
     - a Nondeterminism error from a handler fails the TASK, same as from :Run.
     - eviction with a parked handler emits no failure command and no activation error (drop rule).
     - workflow_failure_exception_types applies to signal handlers.
   - Run; confirm the cancel and continue-as-new cases FAIL today.

2. Verify the Python contract and cite _workflow_instance.py:2518-2565 in test comments.

3. GREEN: Extract one ordered classifier:
   - Add Runner::_classify_failure($err) returning one of evicting / continue_as_new / cancelled / nondeterminism / workflow_failure / task_failure, in that order, built from the existing branches of _outcome_for_failure.
   - _outcome_for_failure consumes it; _settle_signal consumes it and dispatches to the same emitters (cancel path, continue-as-new path, failed completion, activation error).
   - Add a private $evicting field set at the top of evict(); _settle_signal returns early when set (F8 extends this to _settle_update).

4. RED: Add a partition test: a handler-emitted terminal command followed by a state-mutating command in the same activation yields a completion with only the handler-response commands after the terminal one (spec R13 rule).

5. GREEN: In _build_completion, when $workflow_terminal_emitted is set, re-run the _is_handler_response_command partition.

6. REFACTOR: Replace every em-dash on lines I2 added (Runner.pm, sdk/t/lib/WfDef fixtures from I2, the .t header) with commas or parentheses; replace the self-referential line anchors in the I2 comments (~3159, ~3166-3170) with method names; use $_[0] instead of the captured $future in the on_ready closure (~3274).

7. Update documentation: the Runner POD/comments describe the shared classifier and the evicting guard.

8. Verify and run the repo gate (both suites); commit references "Refs #2".
```

### Step F3: Drain a Dead Poll Loop Until Core Shuts Down

**NOTE**: Block from the I3 review. `Worker.pm` `_await_loops_then_drain` (~668-689) waits for surviving loops only; the failed PollLoop stops polling. Core `Worker::shutdown` (`../sdk-rust/crates/sdk-core/src/worker/mod.rs:967-1000`) waits for pending evictions to be polled and replied to (Perl never sets `ignore_evicts_on_shutdown`) and for in-flight activities to finish, so a dead workflow loop with cached runs, or a dead activity loop with a body in flight, wedges `_finalize_and_free`; lessons.md line 14 records it. Python swaps the failed poller for `drain_poll_queue` (`_worker.py:846`; `_activity.py:190`; `_workflow.py:231`) and awaits `wait_all_completed` (`:869`). `PollLoop.pm` (~37-56) leaves `@in_flight` un-awaited on a poll-source die.

```text
1. RED: Write the wedge reproduction first:
   - Extend sdk/t/integration/fatal_poll_unwind.t (skip_all without a dev server) and add a unit-level analog with a fake core in sdk/t/unit/:
     - Start a workflow so a run is cached (let one activation dispatch), then inject a workflow-poll failure; assert run() returns within the harness ceiling with the injected error and no attached secondary "Cannot finalize" error.
     - Inject an activity-poll failure while an activity body is in flight; assert the body's completion is delivered (or a failed "Worker shutting down" completion is sent) and run() returns.
     - Assert post-run state: a second $worker->run dies "Worker is shut down" (or a worker_free spy fires exactly once).
   - Run; confirm the cached-run case FAILS today (times out or wedges; use the harness timeout so the test itself terminates).

2. Verify the Python contract (_worker.py:841-875, _activity.py:190, _workflow.py:231) and cite in comments.

3. GREEN: Implement the per-kind drain:
   - When a loop future is_failed, start a drain for that kind: keep polling that kind; for each task received, send the kind's failed completion ("Worker shutting down", matching Python's drain message) until the poll returns the shutdown signal; include the drain future in the wait before _finalize_and_free.
   - Await the dead loop's in-flight dispatches (PollLoop @in_flight) before finalize, mirroring wait_all_completed.
   - Keep the original error as the raised one; attach finalize failures as secondary only.

4. RED: Add a unit test that two loops failing in the same tick produce one drain per kind and a single raised error.

5. GREEN: Guard double-drain per kind.

6. REFACTOR: Correct the comment at Worker.pm ~670-678 (it mirrors the final asyncio.wait at :857, and now also the :846 drain) and the stale anchors; scrub the em-dashes on the lessons.md line I3 rotated.

7. Update documentation: Worker.pm POD on fatal poll-loop behavior (first failure, drain, finalize, re-raise).

8. Verify and run the repo gate (both suites); commit references "Refs #3".
```

### Step F4: Make the Two-Classes Canary Able to Flip and Its Claims True

**NOTE**: Block from the I18 review. `sdk/t/unit/attribute_handlers.t` (~125-145) wraps the whole `T2->subtest` in `T2->todo`, so the top-level TAP is `ok 5 # TODO` both today and after an upstream fix. The commit body, the upstream-report draft, and the new lessons.md entry (line 5) claim the shape reproduces without Future::AsyncAwait; false: `Temporalio::Workflow` line 8 loads it, and a no-SDK file (`class Base { sub MODIFY_CODE_ATTRIBUTES { () } }` plus two `:isa(Base)` classes with `method run :Run('X') ($i)`) passes `perl -c` and dies under `perl -MFuture::AsyncAwait -c`. The eval-string form does reproduce. Commit bodies are immutable; corrections go in code, lessons, and the session summary.

```text
1. RED: Re-scope the canary so it can flip:
   - In attribute_handlers.t move T2->todo INSIDE the subtest around only the $ok / $@ assertions; add a NON-TODO T2->like($@, qr/Subroutine attributes must come before the signature/) so a wrong-reason failure (for example a renamed :Run handler) goes red instead of hiding a flip.
   - Run prove -lv on the file: expect tests 1-4 plain ok, test 5 ok with inner `not ok # TODO` lines and the like passing; expect NO "TODO passed" line. Document in a comment that an upstream fix will surface as "TODO passed" for the inner assertions and turn the like red, which is the intended alarm.

2. Verify with the no-SDK probe file (write it under the scratchpad, not the repo): perl -c passes, perl -MFuture::AsyncAwait -c dies at the second class; record the exact output.

3. GREEN: Correct the record:
   - Rewrite lessons.md line 5 (the I18 entry) to: two attributed :isa classes back to back in one unit die under Future::AsyncAwait; without it the shape compiles; the earlier "no F::AA needed" reading came from the SDK loading it transitively; fold this as a correction into the 2026-07-10 entry rather than a contradicting sibling.
   - Put the corrected upstream-report draft in the session summary for this step: versions (perl 5.38.2 x86_64-linux-gnu-thread-multi, Future::AsyncAwait 0.71), the five-line no-SDK file, the two one-liners, expected versus actual, negative controls (signature-less methods compile; a second class with no method attribute still dies; a file-scope `sub reset_ {}` between the classes compiles), and where it belongs (the Future::AsyncAwait tracker; the core-only variant with a file-scope signatured sub is a separate perl5 report).

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: none.

7. Update documentation: the canary comment cites the corrected lessons entry and GitHub #18 and states the flip signal precisely.

8. Verify and run the repo gate (both suites; the single file must show no "TODO passed"); commit references "Refs #18".
```

### Step F5: Re-vendor Cloud, Test, and Health Protos From the Pinned Tag

**NOTE**: Block from the I12 review; the orchestrator's provenance claim was wrong. `git -C ../sdk-rust ls-tree -r --name-only v0.4.0` shows the four trees under `crates/common/protos/` (the crate moved to `crates/protos/protos/` after the tag). Eighteen of nineteen vendored files are byte-identical to the tag; `temporal/api/cloud/connectivityrule/v1/message.proto` differs (HEAD adds `enable_stable_ips`, which the installed 0.4.0 bridge's prost decode silently drops). `Core/Proto.pm` `load()` parses every root eagerly: measured 67 files / 1.9s / 41 MB before I12 versus 87 / 2.6s / 46 MB after. `%RPC_SERVICE` codes are a file lexical no test reads.

```text
1. Scope:
   - Artifact(s): sdk/share/proto/{temporal/api/cloud/**,temporal/api/testservice/v1/*,grpc/health/v1/health.proto,protoc-gen-openapiv2/**}, sdk/lib/Temporalio/Core/Proto.pm, sdk/lib/Temporalio/Client/Connection.pm, sdk/t/unit/raw_service_extra.t, .ai-sessions/lessons.md.
   - Desired end state: every vendored file byte-identical to `git show v0.4.0:crates/common/protos/<path>`; the false provenance sentences removed from the test ABOUTME and the lessons entry (rewrite line 5's I12 entry to: the tag holds these trees under crates/common/protos; compare against the tag path, not the HEAD path); service codes pinned by a test; cloud and test trees loaded lazily if feasible.

2. Tooling:
   - Skills: temporal:temporal-developer
   - MCPs: none
   - External: git, cmp, diff -rq.

3. Do the work:
   - For each vendored file, `git -C ../sdk-rust show v0.4.0:crates/common/protos/<rel> > sdk/share/proto/<rel>`; then `diff -rq` each tree against a `git archive v0.4.0 crates/common/protos/<tree>` extraction; expect no differences (connectivityrule reverts).
   - Add `Temporalio::Client::Connection->_service_code($name)` (class-level accessor over %RPC_SERVICE) and assert 3/4/5 in raw_service_extra.t against header lines 8-14; assert one response_class (`...Cloud::Cloudservice::V1::GetUsersResponse` or the actual resolved name) on a captured call.
   - Probe whether Protobuf::Schema tolerates adding the cloud and testservice roots after the first resolve (write a scratch script). If yes: load those two trees lazily from the CloudService/TestService ADJUST (health stays eager; it is one file) and add a test that schema() before any cloud use does not contain the cloud service while a CloudService handle construction makes it resolvable. If no: keep eager loading and add a POD paragraph in Core/Proto.pm stating the measured cost and why.
   - Rewrite the lessons.md I12 entry; fix the ABOUTME lines in raw_service_extra.t.

4. Verify:
   - diff -rq shows the four trees identical to the tag; both suites exit 0.

5. Document:
   - Session summary records the corrected provenance and, if lazy loading landed, the before/after schema() timing; commit references "Refs #12".
```

### Step F6: Make Fork-Pool Frame Pairing Token-Exact

**NOTE**: Warns from the I7 review. `Pool.pm` `_child_drain_control` (~822-834) keys the cancelled flag by token but writes `$child->{holder}{details}` unconditionally, so a late cancel for a finished token lands in the next invocation's holder on the same child. `Context.pm` `_record_heartbeat` (~245-251) sends `hbd` BEFORE `encode_heartbeat_bytes`, so a failed encode leaves an orphan `hbd` that pairs with a later `hb`. The parent's chain-failure fallback (~560-566) relays and records where the async path (`Context.pm:236-243`) records nothing; the comment cites a Python try/except at `_activity.py:838-844` that does not exist (thread executors propagate via `.result(10)` at 851-853). The race test (~433-511) arms the hold AFTER `start`, so the rejected `%token_conn` guard would pass it; `control_connected` is proven only by the summary's stress loop.

```text
1. RED: Write pairing tests first:
   - Extend sdk/t/unit/pool_cancellation_details.t: send a cancel frame for token A after A's end frame while B runs on the same child; assert B's cancellation_details stay undef and is_cancelled false.
   - Extend sdk/t/unit/pool_heartbeat_interceptor.t: a body whose first heartbeat detail fails encoding and whose second heartbeat succeeds must relay the SECOND detail's args to the chain, never the first's.
   - Chain dies: assert the heartbeat is NOT recorded (relay not called), only warned, matching the async path.
   - Hold-at-accept race variant: arm the hold in _accept_control before any drain so the reply lands with %token_conn empty; assert the chain still observes the heartbeat (this is the reply-before-start case control_connected exists for).
   - Parity subtest: assert is_worker_shutdown matches across pooled and async paths after notify_shutdown on both.
   - Run; confirm the first three FAIL today.

2. Verify the Python contract (_activity.py:813-818, 851-865, 283-305) and correct the citation in the Pool.pm comment.

3. GREEN: Fix the child and parent:
   - Record $child->{holder_token} where the holder is bound (~915) and guard the holder write with token equality.
   - Call heartbeat_details_recorder only after encode_heartbeat_bytes succeeds (or tag hbd/hb with a per-invocation sequence and pair only on match; choose the simpler, document the choice).
   - On chain failure: warn and drop; do not relay the child's bytes.

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: Reword the $hold_after_start field comment (it applies to every start until release); drop the stale citation.

7. Update documentation: Pool.pm POD on frame pairing guarantees and the chain-failure rule.

8. Verify and run the repo gate (both suites); commit references "Refs #7".
```

### Step F7: Honor Dynamic Update Validators on Every Path

**NOTE**: Warns from the I9 review. `Definition.pm` (~86-101) stores `:UpdateValidator('method')` into `$_DEFS{$pkg}{validators}{method}`; `Runner::_handlers` (~3342) never maps it into `{dynamic}{update_validator}`, so an attribute-declared validator for a dynamic `:Update` is ignored. `grep validate_update Runner.pm` is empty: the inbound chain's `validate_update` (Interceptor.pm:95, TracingInterceptor.pm ~628) is never invoked; Python runs the validator inside `handle_update_validator` (`_workflow_instance.py:650`). A validator returning a pending Future is accepted (~3710-3714). Untested: the no-fallback rule, rejection message/type, install/uninstall symmetry.

```text
1. RED: Write validator tests first:
   - Extend sdk/t/replay/dynamic_update_validator.t:
     - a fixture with :Update(dynamic=1) plus :UpdateValidator by attribute: a rejecting validator rejects the dynamic update.
     - a named :Update WITHOUT validator alongside a dynamic validator that dies: the named update is accepted unvalidated (no fallback).
     - the rejection carries the validator's message and application_failure_info.type.
     - set_dynamic_update_handler without validator clears a previous validator; removing the handler drops the validator.
     - an inbound interceptor overriding validate_update observes the call (record and delegate) for both named and dynamic updates.
     - a validator returning a pending Future is rejected as a task failure (or rejection; match Python's synchronous contract and document).
   - Run; confirm the attribute, interceptor, and pending-Future cases FAIL today.

2. Verify the Python contract (_workflow_instance.py:650-658, 1245-1250, 2938-2941, _handlers.py:382) and cite.

3. GREEN: Wire and route:
   - _handlers maps an attribute validator whose name matches the dynamic :Update method into dynamic => { update_validator => ... }.
   - Run the validator through $workflow_inbound->validate_update($input) under the read-only depth with a _root coderef like handle_update.
   - Guard: if the validator's return is a Future that is not ready, treat as a validator error per the documented rule.

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: Reword Workflow.pm POD (~851) from "fallback" to "the dynamic definition's own validator".

7. Update documentation: validators must be synchronous; attribute and runtime registration both honored.

8. Verify and run the repo gate (both suites); commit references "Refs #9".
```

### Step F8: Settle Handlers Silently During Eviction

**NOTE**: Warns from the I1 review; depends on F2's $evicting field. After the sweep reorder, a condition-parked update resumes with Cancelled (a failure, not a native cancel), takes `_update_settlement`'s rejected branch (~3765-3781), pushes an UpdateResponse and runs the failure converter mid-evict; a converter die would escape `evict()`. Python swallows anything under `_deleting` (`_workflow_instance.py:485-490`). The R17 comment now describes the old behavior. The existing test can be defeated by wrapping evict in eval; the "exactly one completion" assertion is tautological. No "tasks remain" tripwire (Python :504-509).

```text
1. RED: Write eviction tests first:
   - Extend sdk/t/replay/evict_pending_update_wait_condition.t:
     - a wait_condition-parked async :Signal handler under evict: no failure command, no activation error, no croak.
     - the park helper counts Cancelled resumptions in a package variable; assert exactly 1 per parked handler.
     - weaken a runner reference; assert it is freed after eviction (no cycle).
     - a failure converter that dies during evict does not escape evict().
   - Run; confirm the converter-dies case FAILS today.

2. Verify the Python contract (:485-490, :799-808) and cite.

3. GREEN: _settle_update returns early when $evicting (from F2); update the R17 comment to describe the two arms (dropped for plain-future parks, silently dropped for condition parks under evict).

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: State the sweep-order invariant in the evict comment: every awaitable class with a fail-on-cancel override (timers, activities, conditions) is swept before the handler pass; plain Temporalio::Workflow::Future clones cancel natively. Fix the "AWAIT_CLONE of its underlying _ConditionFuture" wording (Future.pm:232 clones the first-awaited class).

7. Update documentation: note the missing "tasks remain" tripwire as a follow-up in the session summary (do not implement here).

8. Verify and run the repo gate (both suites); commit references "Refs #1".
```

### Step F9: Keep Untyped Search Attributes Through Schedule Action Decode

**NOTE**: Warns from the I4 review. `Schedule/Action.pm` (~304-308) and `Common/TypedSearchAttributes.pm` (~193-197) drop search attributes whose payload has no recognized type metadata; Python keeps them in `untyped_search_attributes` (`client/_schedule.py:718-728`) and re-encodes on update (`:843-850`). `TypedSearchAttributes.pm:193` dereferences `metadata` without a `// {}` guard. `SearchAttributeKey.pm` `decode_value` (~151-155) assumes json/plain and dies on other encodings where Python skips (`converter/_search_attributes.py:183-202`). `RetryPolicy.pm` `_from_proto` (~78-83) lets unset fields on hand-built protos override the 2.0/0 defaults. The no-optional-fields subtest never asserts priority is undef.

```text
1. RED: Write decode tests first:
   - Extend sdk/t/unit/schedule_action_roundtrip.t:
     - a search attribute payload with no type metadata survives describe-to-update (either as an untyped residual re-sent on update, or, if spec 7.4 forbids untyped input, the limitation is asserted explicitly and documented).
     - _to_proto(_from_proto(x)) is byte-identical for the fully populated action (encode both, compare bytes).
     - a wire-crossing round trip (decode(encode)) covering Bool, Datetime, Double, Int, Keyword, KeywordList, Text values.
     - a Payload with undef metadata does not die in TypedSearchAttributes.
     - a binary/null-encoded SA payload is skipped, not fatal.
     - RetryPolicy _from_proto on a ->new-built proto yields backoff 2.0 and maximum_attempts 0.
     - the no-optional-fields subtest asserts !defined priority.
   - Run; confirm the residual, metadata-undef, and skip cases FAIL today.

2. Verify the Python contract (_schedule.py:684-744, 718-728, 843-850; _search_attributes.py:183-202) and cite.

3. GREEN: Implement the residual (preferred) or the documented limitation; add the metadata guard; make decode_value skip on failure; apply proto3 defaults in RetryPolicy _from_proto.

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: One helper for "decode a search attribute payload or skip" shared by Action.pm and TypedSearchAttributes.pm.

7. Update documentation: Action.pm POD on untyped residual handling.

8. Verify and run the repo gate (both suites); commit references "Refs #4".
```

### Step F10: Round the Shared Duration Pair Correctly

**NOTE**: Warns from the I14 review. `Core/Proto.pm` `duration_from_seconds` (~98-121): `int(($seconds - $whole) * 1e9 + 0.5)` is wrong for negative fractions (-1.5 gives nanos -499999999) and can yield nanos of 1_000_000_000 for fractions within half a nanosecond of the next second. protobuf `FromTimedelta` normalizes to same-sign nanos exactly. `Schedule/Spec.pm` ~104 comment points at `.ai-sessions/implementation-notes.md`, which finalize deletes.

```text
1. RED: Write rounding tests first:
   - Extend sdk/t/unit/proto.t T-proto-6: -1.5 gives (-1, -500000000); -0.25 gives (0, -250000000); 0.9999999999 gives (1, 0) with carry; 2.9999999996 gives (3, 0); "1.5" string input; NaN and Inf either die with Temporalio::Exception::Argument or are documented as caller-validated (choose, document); seconds_from_duration inverts each.
   - Extend sdk/t/unit/schedule_types.t: a zero Duration for jitter decodes to undef (the Spec.pm fold).
   - Run; confirm negative and carry cases FAIL today.

2. Verify against protobuf well_known_types.py _NormalizeDuration semantics (cite the file in ../sdk-python's environment if present, else the protobuf docs) in comments.

3. GREEN: Sign-aware rounding: nanos = int(abs(frac) * 1e9 + 0.5) * sign; carry into seconds when nanos reaches 1e9.

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: Fix the Spec.pm ~104 comment to point at the I14 session summary or drop the pointer.

7. Update documentation: POD on the pair states the rounding and carry rules.

8. Verify and run the repo gate (both suites); commit references "Refs #14".
```

### Step F11: Prove fetch_history Pages

**NOTE**: Warns from the I11 review. `sdk/t/unit/fetch_history.t` scripts exactly one response per subtest with no next_page_token; the option pass-through subtest (~239-247) discards `$calls` and uses the default event_filter_type. `HistoryEventIterator.pm` paging has no unit coverage. `workflow_handle_result.t:380-408` shows the two-page responder pattern for list_workflows.

```text
1. RED: Write paging tests first:
   - Extend sdk/t/unit/fetch_history.t: a two-page responder (first response next_page_token 'tok1' with events 1-5, second with events 6-10 and no token); assert the second request carries next_page_token 'tok1', 10 events in order, and byte-identity of the concatenation with the expected history.
   - Capture $calls in the options subtest; pass event_filter_type => 2 (CLOSE_EVENT), page_size => 5, skip_archival => 1; assert maximum_page_size, history_event_filter_type, and skip_archival on the first request.
   - Run; confirm a one-page implementation would fail (temporarily short-circuit locally to prove the RED, then restore).

2. Verify the Python contract (_workflow.py:391-415, 451) and cite.

3. GREEN: Fix anything the tests expose; otherwise no production change.

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: none.

7. Update documentation: fetch_history POD sentence on run_id pinning (a handle from start_workflow pins the first run; use a run_id-less handle to follow continue-as-new).

8. Verify and run the repo gate (both suites); commit references "Refs #11".
```

### Step F12: Keep the Real Run Future Alive and Observed on a Wedged Shutdown

**NOTE**: Warns from the I5 review. `Test/Worker.pm` (~222-223): on timeout the shielded run future is left pending with no continuation, so a late failure is a lost failed Future and the "no orphaned processes" contract comment (~206-207) no longer holds on that branch. `sdk/t/unit/test_worker_shutdown.t` (~41-50) never asserts the real run future survives uncancelled (FakeWorker exposes `$worker->{run_future}`). `await_result` POD (~296-298) is wrong (it is synchronous). todo.md line 45 wording is muddled.

```text
1. RED: Write the shield test first:
   - In test_worker_shutdown.t subtest 1, after the like: assert !$worker->{run_future}->is_ready && !$worker->{run_future}->is_cancelled.
   - Add a subtest where the run future FAILS during the await race (settle from $loop->later), asserting the failure is re-raised.
   - Add a subtest that a run future which settles failed AFTER the timeout has its failure retrieved (no "lost a failed Future" warning; capture warnings).
   - Run; confirm the retrieval case FAILS today.

2. Verify: none (harness code); note the Python/Ruby harness comparison in a comment.

3. GREEN: Before the die, attach $run_future->on_ready(sub {}) or ->retain with a diag on failure; qualify the contract comment (teardown of a wedged worker is left to the caller's END block because finalize would deadlock on the undrained poll).

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: Fix the await_result POD; align todo.md line 45 wording to "two-arm vs three-arm".

7. Update documentation: shutdown POD states the timeout branch's guarantees.

8. Verify and run the repo gate (both suites); commit references "Refs #5".
```

### Step F13: Prove result_type Reaches the Converter

**NOTE**: Warns from the I8 review. `sdk/t/unit/start_update_result_type.t` (~97-127) asserts the accessor and a kwargs spy; `make_client` uses a stock `Temporalio::Converter::Data` whose converters ignore hints, so `_decode_all_payloads` (`WorkflowUpdateHandle.pm:133-134`) passing undef would still pass. The polling branch (no outcome from UpdateWorkflowExecution, answered by PollWorkflowExecutionUpdate) is untested. Handle POD (~178-184, ~158-161) names only get_update_handle; WorkflowHandle.pm ~487-491 cites stale anchors; `result_type` travels in the interceptor input's `opts` hashref without POD.

```text
1. RED: Write converter tests first:
   - Add a payload converter subclass whose from_payload($p, $hint) records $hint; build the client with it; assert the recorded hint is 'My::ResultType' on start_update ... ->result, on execute_update, and on the polling branch.
   - Run; confirm they FAIL if _decode_all_payloads passes undef (temporarily break locally to prove RED, then restore).

2. Verify the Python contract (client.py:787, :903, :971; _impl.py:766; :1929-1932) and cite.

3. GREEN: Fix anything exposed; otherwise no production change.

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: Replace the stale anchors in WorkflowHandle.pm comments with method names.

7. Update documentation: WorkflowUpdateHandle POD names start_update and execute_update as constructors that set result_type; Interceptor.pm POD documents the opts keys for StartWorkflowUpdate (wait_for_stage, update_id, result_type).

8. Verify and run the repo gate (both suites); commit references "Refs #8".
```

### Step F14: Bound Priority to What the Wire Carries

**NOTE**: Warns from the I10 review. `Common/Priority.pm` guard (~54-60) has no upper bound: `Priority->new(priority_key => 2**31)` constructs and dies later at encode with `Protobuf::Exception::Codec::OutOfRange`; the proto field is int32 (`message.proto:318`). Objects with overloaded numification pass and die at encode with TypeMismatch. The guard comment (~48-49) understates what is accepted (" 1", "1e0", "1.0", "+1" pass).

```text
1. RED: Write boundary tests first:
   - Extend sdk/t/unit/priority_fairness.t: 2**31 and 3e9 are rejected at construction with Temporalio::Exception::Argument; 2**31 - 1 is accepted; an object with overloaded 0+ is rejected; priority_key => "3" round-trips to_proto as 3 (pins the documented divergence from Python's isinstance(int)).
   - Run; confirm the first two FAIL today.

2. Verify the Python contract (common.py:1222-1228) and cite.

3. GREEN: Add `|| ref $priority_key || $priority_key > 2_147_483_647` to the guard.

4. RED: none further.

5. GREEN: none further.

6. REFACTOR: Widen the guard comment to list what is accepted (whitespace-padded, exponent, and "+1" forms numify cleanly) and what is rejected.

7. Update documentation: Priority POD states the int32 bound.

8. Verify and run the repo gate (both suites); commit references "Refs #10".
```

### Step F15: Pin the count_workflows Group Shape (task)

**NOTE**: Nit from the I13 review. `sdk/t/unit/count_workflows_shape.t` (~87-90) builds both aggregation groups with `group_values => []`, so the POD's "raw Payload proto objects" claim is unasserted. Client.pm POD (~1245-1247) says "decode them with the client's data converter", which has no `decode` method; the public single-payload path is the payload converter's from_payload. `$query` is optional (Client.pm ~303 sends '' when undef) but the POD does not say so.

```text
1. Scope:
   - Artifact(s): sdk/t/unit/count_workflows_shape.t, sdk/lib/Temporalio/Client.pm POD.
   - Desired end state: one group carries a Payload and the test asserts its class; POD names the public decode accessor and states $query may be omitted.

2. Tooling:
   - Skills: none
   - MCPs: none
   - External: podchecker.

3. Do the work:
   - Give one mocked group `group_values => [ $Payload->new({ metadata => { type => 'Keyword', encoding => 'json/plain' }, data => '"x"' }) ]` and assert the decoded group's group_values->[0] isa the Payload proto class.
   - Rewrite the POD sentence to name `$client->data_converter->payload_converter->from_payload($payload)` (or the actual public accessor; verify it exists) and mention metadata->{type}; add "omit $query to count every execution in the namespace".

4. Verify:
   - prove -lv t/unit/count_workflows_shape.t exits 0; both suites exit 0; podchecker on Client.pm is clean.

5. Document:
   - none beyond the POD; commit references "Refs #13".
```


## Implementation Guidelines

- **Order.** Sections run top to bottom; the four Section 1 bugs ship first because they turn loud failures into silent ones or hangs. Within a section, steps are independent unless a NOTE says otherwise, so `/bpe:goal` may take them in listed order.
- **One issue per commit.** Each step lands exactly one green commit carrying `Closes #N`. Never commit to main (CLAUDE.md); work on a feature branch and open a PR.
- **Reproduce first, always.** A step starts with the RED test that fails for the documented reason (Directive 1). The two exceptions are I13 (POD fix with an exercising shape assertion, green from the start) and the two Section 5 tasks; each says so explicitly.
- **Fixtures obey I18.** Every new workflow/activity fixture with a handler attribute is one attributed class per file under `sdk/t/lib/` (Directive 6), even before the I18 canary lands.
- **Replay over live.** Prefer `sdk/t/replay/` for deterministic behavior; integration tests skip_all offline; hang/crash repros are subprocess-guarded, and prefer a deterministic unit-level guard when the logic can be driven without a server (I3).
- **Shim only for I7, and only if forced.** No other step touches `ext:`. If I7's heartbeat relay cannot be framed in pure Perl, the memory guard and shim protocol (Directive 7) are mandatory: `CARGO_BUILD_JOBS=2`, foreground, `cargo test`, cbindgen regen, Alien rebuild.
- **POD travels with behavior.** Directive 5: `prove -lj4 xt` stays green in every step that touches public behavior.
- **Verify against the pinned header.** FFI/discriminator work (I12) checks `../sdk-rust/crates/sdk-core-c-bridge/include/temporal-sdk-core-c-bridge.h` at the pinned tag, not memory.

## Success Metrics

- All 15 steps checked in `todo.md`; each GitHub issue (#1-#14, #18) closed by its landing commit.
- `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )` exits 0 after every step.
- `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )` exits 0 after every POD-touching step.
- If I7 touched `ext:`: `( cd ext/temporalio-perl-bridge && cargo test )` green and the Alien rebuild succeeded under the memory guard.
- Every behavior fix ships a permanent repro (RED-first); no behavior change lands without a test that fails without it.
- I14 leaves exactly one Duration conversion pair; I18's canary is TODO-green and flips on an upstream fix.
