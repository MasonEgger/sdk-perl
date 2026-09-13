# sdk-perl Issue-Closeout Specification

## Overview

This spec defines the required behavior for the 15 open GitHub issues (#1-#14 and #18) that were filed during the R1-R97 remediation cycle and deferred as known follow-ups.
The R1-R97 contract, its plan, and its todo are archived at `.ai-sessions/r1-r97-remediation/`; that spec carried the SDK to reference-SDK parity, and each of these issues was scoped out of its discovering step deliberately to keep that cycle atomic.
This document holds the code to closing every one of them.

The prime directive is unchanged (archived spec §0, inherited from v1): Temporal-spec semantics first, Perl idioms second.
Any behavior consistent across two or more reference SDKs is the de facto contract.
Where a requirement cites Python, the sibling checkout `../sdk-python` is the ground truth and the fix is verified against that source at implementation time, never from memory.

Requirement IDs are the GitHub issue numbers (I1-I14, I18) so this spec, `plan.md`, `todo.md`, and the issue tracker stay 1:1.
Each landed step references its issue so the commit can carry `Closes #N`.

Citation convention (matching the archived spec): module paths are relative to `sdk/lib/Temporalio/`; the `ext:` prefix means `ext/temporalio-perl-bridge/src/lib.rs`; `t/` and `xt/` paths are under `sdk/`.

## Scope

In scope: the 15 open issues, grouped into five bands by risk and area.

1. **Silent-failure correctness bugs.** I2 (sync signal die swallowed), I3 (fatal poll-loop never unwinds run), I1 (evict of an async update parked on wait_condition croaks), I5 (Test::Worker shutdown reports success on a wedge). These turn a loud failure into a silent one or a hang; they ship first.
2. **Schedule round-trip data loss.** I4 (Action `_from_proto` drops user_metadata and most optional fields).
3. **Small parity gaps.** I8 (start_update result_type), I10 (Priority.priority_key validation), I13 (count_workflows POD + shape assertion), I11 (WorkflowHandle fetch_history), I9 (dynamic update validator wired or rejected).
4. **Larger parity features.** I7 (fork-pool heartbeat interceptor chain + cancellation_details in children), I6 (OTel workflow-outbound spans), I12 (cloud/test/health raw service handles).
5. **Cleanup and upstream canary.** I14 (Duration conversion dedup; POSIX import re-verified), I18 (two-attributed-classes-per-file compile canary + upstream note).

Out of scope: any behavior beyond these 15 issues. New defects found while fixing them are filed as fresh issues, not folded in.

## Available Tooling

Tools the `bpe:validator` agent should consult when reviewing diffs in `/bpe:goal` runs.
`/bpe:plan` propagates these to per-section declarations in plan.md.

**MCPs:**
- mcp__temporal-docs__search_temporal_knowledge_sources (activation protocol, cancellation types, codec boundaries, update/query semantics, schedule/user-metadata, tracing, replay contracts)

**Skills:**
- temporal:temporal-developer

**Repo gates:**
- `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )` for the unit/replay/integration suite; integration files `skip_all` without a dev server.
- `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )` for author tests (POD syntax and coverage).
- `( cd ext/temporalio-perl-bridge && cargo test )` for the Rust shim; `dzil test` per distribution.
- Every cargo, Alien, or dzil build follows the CLAUDE.md memory guard: `CARGO_BUILD_JOBS=2` (retry once at 1 on an OOM or signal death), foreground only, generous timeout; never background a build.
- Any change to `ext:` follows the shim protocol: `cargo test`, regenerate the cbindgen header, rebuild the installed `Alien::Temporalio::PerlBridge` (the P0.10 precedent).

**Verification command:** `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )`

**Notes:** validator should hold every diff to §0 parity, verifying MUST-match semantics against the sibling checkouts (`../sdk-python` first), not from memory. Reproduce-first: no fix without a RED test that fails for the documented reason. Every commit is green.

## Global Requirements

1. **Reproduce before fixing, inside each step.** Every defect ships a failing test that fails for the documented reason; reproduction and fix land in the same commit so the suite is always green and the repro is permanent coverage. Parity items assert the missing capability against the cited Python source.
2. **Replay over live where deterministic.** Command-sequence and workflow-context behavior go in `sdk/t/replay/` (offline). Use `sdk/t/integration/` only for genuine timing/live paths; crash/hang repros run subprocess-guarded via `sdk/t/lib/SubprocessGuard.pm`. Unit tests go in `sdk/t/unit/`, author/POD tests in `sdk/xt/`.
3. **Parity to Python source, verified at implementation time.** The GREEN checks the cited `../sdk-python` file, not memory.
4. **Test only your logic.** RED phases test the defect behavior and the fix's observable contract (emitted command, completion outcome, codec touch, typed error, interceptor invocation, decoded field), never framework, library, or language behavior.
5. **POD in the same change.** A fix that alters public behavior updates the POD in the same commit; `prove -lj4 xt` stays green.
6. **Shim changes follow the memory guard.** Any `ext:` change uses `CARGO_BUILD_JOBS=2`, foreground builds, then `cargo test`, cbindgen regen, and Alien rebuild. Only I7 may touch the shim.
7. **One attributed class per file.** New test fixtures with a handler attribute (`:Run`/`:Signal`/`:Query`/`:Update`/`:Init`/`:Defn`) live one-per-file under `sdk/t/lib/` (the I18 constraint); a base with no attributes may be shared. This holds for every new fixture in every step.

## Requirements

### I2: A die inside a synchronous :Signal handler must fail the workflow task

**What is wrong.** An exception thrown inside a synchronous `:Signal` handler is silently swallowed.
`Runner::_dispatch_signal` (`Workflow/Runner.pm:3164`) wraps the handler in `Future->call`; the resulting already-failed future is not tracked in `%in_progress_handlers` and never observed, so the die vanishes.
The signal appears delivered, the handler's side effects are partial, and nothing surfaces.

**Required behavior.** A die in a sync signal handler becomes a failed workflow task, matching Python (which fails the workflow task when a signal handler raises).
Route the failed signal-handler future into the same die-to-failed-completion funnel R11 built (`Worker/WorkflowDispatcher.pm` catch-all).
Confirm the async `:Signal` path (already tracked through `%in_progress_handlers`) already reports; if it does not, fix it in the same step.

**Acceptance.** A replay test delivers a signal whose handler dies and asserts a failed WFT completion is produced instead of a normal completion.

### I3: A fatal poll-loop death must unwind Worker::run

**What is wrong.** `Worker::run` (`Worker.pm:571`, the `Future->wait_all(@loops)` at :615) waits for every poll loop, so one loop dying fatally leaves the healthy loops polling forever and `run()` never returns.
`_finalize_and_free` can also deadlock because core still holds undrained poll calls.
The R94 `on_fatal_error` hook fires only because its test initiates shutdown; the organic fatal path still wedges.

**Required behavior.** Python parity (`../sdk-python` `worker/_worker.py:813,846-848`) in two parts:
1. Replace `wait_all` over the poll loops with a first-failure race so one fatal loop triggers shutdown of the rest (`asyncio.wait(..., return_when=FIRST_EXCEPTION)` analog).
2. On the fatal path, initiate core shutdown and drain the outstanding polls (they resolve with the shutdown sentinel) before `_finalize_and_free`, mirroring `drain_poll_queue`.

**Acceptance.** A subprocess-guarded integration test where one poll loop dies fatally: `run()` returns the error within a bound, healthy loops are stopped, no finalize deadlock.

### I1: Evicting a run with an async :Update parked on wait_condition must not croak

**What is wrong.** Evicting a run holding an in-flight async `:Update` handler parked on `wait_condition` croaks inside the runner and never sends the RemoveFromCache completion.
The handler's method future is a Future::AsyncAwait AWAIT_CLONE of the internal `_ConditionFuture`.
Evict's handler sweep cancels the clone (failing it with Cancelled); the conditions sweep then fails the real parked condition future; the resuming async frame dies; Future::AsyncAwait tries to fail the already-failed method future, producing "... is already failed and cannot be ->fail'ed".
This is the handler-future sibling of the R8-R10 post-cancel cluster.

**Required behavior.** Teach the evict path (`Workflow/Runner.pm:2169` `evict()`, its handler sweep and the conditions sweep near :2020 / :3023) to discriminate AWAIT_CLONEd handler futures the same way the R8-R10 fix taught the cancel fallback: sweep the parked condition future first, or skip the handler-clone cancel when its underlying condition is in the pending-conditions table, so only one settle reaches the method future.

**Acceptance.** A replay test mirroring `evict_pending_update.t` but with the handler parked on `wait_condition`: evict completes and sends the eviction completion; no "already failed" die.

### I5: Test::Worker shutdown() must raise when the drain wedges

**What is wrong.** `Test/Worker.pm:208` `shutdown()` awaits `wait_any($run_future, $timeout_future)` with an unshielded run future.
On timeout, `wait_any` cancels the losing run future, making it ready without being done or failed, so the `unless $run_future->is_ready` guard never fires and `is_failed` is false: a wedged worker looks like a clean shutdown.

**Required behavior.** Apply the pattern commit b3facf7 established (already used in the same file's `run` path at :38): await `$run_future->without_cancel` in the race so the timeout cannot poison it, then branch on the actual loser state so the wedged-drain diagnostic is reachable and `shutdown()` raises on a wedge.

**Acceptance.** A unit test stalls the drain and asserts `shutdown()` raises the diagnostic instead of returning success (mirror the R46/R47 cases in `sdk/t/unit/devserver_shutdown.t`).

### I4: Schedule Action _from_proto must carry every field _to_proto writes

**What is wrong.** `Schedule::Action::StartWorkflow::_from_proto` (`Schedule/Action.pm:142`) rebuilds the action from a DescribeSchedule response but drops user_metadata (static_summary/static_details), timeouts, retry_policy, memo, search_attributes, headers, and priority.
A describe-modify-update round trip silently strips those fields, undoing the R82 encode side.

**Required behavior.** Complete `_from_proto` to carry every field `_to_proto` (`Schedule/Action.pm:77`) writes: decode user_metadata back to static_summary/static_details (pass-through Payload semantics, matching Python's raw-Payload round trip), plus timeouts, retry_policy, memo, search_attributes, headers, and priority.

**Acceptance.** A round-trip unit test asserts `_from_proto(_to_proto($action))` preserves every populated field; an integration describe-modify-update test asserts static_summary survives (skip_all without a dev server).

### I8: start_update must accept result_type

**What is missing.** `WorkflowHandle::start_update` (`Client/WorkflowHandle.pm:488`) does not accept a `result_type` decode hint, though `get_update_handle` (:577) does and threads it into the shared `_update_handle` (:595) constructor.

**Required behavior.** Accept `result_type` in `start_update` (and `execute_update` at :475, which delegates), pass it to `_update_handle`, add it to the known-options list so the R44 strictness validator admits it, and document it in POD.

**Acceptance.** Extend `sdk/t/integration/get_update_handle.t` or the update unit tests with a decode-hint assertion on a `start_update` result.

### I10: Priority.priority_key must be validated at construction

**What is wrong.** `Common/Priority.pm` ADJUST (:26) validates the new fairness_weight but not priority_key, despite the comment citing the priority_key guard.
Python rejects a non-integer or sub-1 priority_key at construction (`../sdk-python` `common.py` Priority `__post_init__`); Perl accepts anything and lets it reach the proto encode.

**Required behavior.** Add an ADJUST-time guard: `priority_key` must be a positive integer (>= 1) when defined, raising `Temporalio::Exception::Argument` otherwise.

**Acceptance.** Extend `sdk/t/unit/priority_fairness.t` with the rejection cases (undef allowed, >=1 integer allowed, 0 / negative / non-integer rejected).

### I13: count_workflows POD must document the { count, groups } return shape

**What is wrong.** The `count_workflows` POD (`Client.pm:1226`) says the method resolves "to the count", but the method returns `{ count => N, groups => [...] }` (`Client.pm:300`).
A caller following the docs does arithmetic on a hashref.

**Required behavior.** Correct the POD to document the `{ count, groups }` return shape with a short example for both the plain and group-by forms, matching Python's CountWorkflowsResponse handling.

**Acceptance.** A unit assertion on the return shape (the R64 pattern: every corrected POD claim gets an exercising test) plus green `prove -lj4 xt`.

### I11: WorkflowHandle must expose fetch_history

**What is missing.** `WorkflowHandle` has no `fetch_history` convenience method, though the parts exist since R95: `fetch_history_events` (`Client/WorkflowHandle.pm:609`) and `Temporalio::Client::WorkflowHistory` with `from_json`/`to_json`.

**Required behavior.** Add `fetch_history` to WorkflowHandle that assembles a `WorkflowHistory->new(workflow_id => ..., events => [...])` from `fetch_history_events` (Python-parity naming, `client/_workflow.py:391`), with a POD entry.

**Acceptance.** A unit test asserts the assembled history replays through `Test::WorkflowReplay::replay_workflow` identically to a from_json load.

### I9: The dynamic update handler validator must be wired or rejected

**What is wrong.** `Workflow::set_dynamic_update_handler` accepts a `validator` argument for Python signature parity but silently ignores it (`Workflow/Runner.pm:3389` comment: "a validator passed with a dynamic install is ignored").
An update routed to the dynamic handler is never validated, so a caller relying on validator rejection gets accept-then-execute.

**Required behavior.** Wire the dynamic update validator into the update validation path (`_apply_do_update` at `Runner.pm`, step 3): when a named validator lookup misses, fall back to the dynamic definition's validator, matching Python (`../sdk-python` `_workflow_ops.py` dynamic update definition validator fallback).
Accepting-but-ignoring a load-bearing argument is the worst option; wire it.

**Acceptance.** A replay test registers a dynamic update handler with a rejecting validator and asserts the update is rejected (not executed); a passing validator admits it.

### I7: Fork-pool activities must run the heartbeat interceptor chain and expose cancellation_details

**What is missing.** Two capability gaps for sync (fork-pool) activities, both documented today as §0 deviations.
1. The activity heartbeat interceptor chain is bypassed: the pool relay (`Activity/Pool.pm`) carries already-serialized ActivityHeartbeat bytes, so there is nothing chain-shaped for a parent-side ActivityOutbound interceptor to observe. Python relays structured details parent-side through the chain (`register_heartbeater(ctx.heartbeat)`).
2. `cancellation_details` is unavailable in pool children (`Activity/Context.pm`): the details holder does not cross the fork boundary, so a pooled activity sees undef where an async activity sees the reason flags. Worker-shutdown detection degrades the same way.

**Required behavior.** Extend the pool control-channel protocol (R4/R18/R19) to carry structured data both ways:
- Child-to-parent: relay Perl-level heartbeat details (not serialized bytes) so the parent runs the ActivityOutbound chain (`Worker/ActivityDispatcher.pm`) before forwarding to core.
- Parent-to-child: forward the cancellation reason and details alongside the existing cancel delivery so the child context populates `cancellation_details` and the distinct worker-shutdown event.

**Acceptance.** A pooled activity whose interceptor observes the heartbeat, and a pooled activity that reads `cancellation_details` after a reasoned cancel. If the control-channel change requires an `ext:` edit, the shim protocol (Global Requirement 6) applies; if it is pure Perl over the existing channel, no shim rebuild.

### I6: OpenTelemetry workflow-outbound spans must ride the interceptor chain

**What is missing.** The OTel TracingInterceptor (`Contrib/OpenTelemetry/TracingInterceptor.pm`) does not create spans or inject trace context for operations started from workflow code: execute_activity, start_child_workflow, signal_child_workflow, signal_external_workflow, start_nexus_operation.
Client calls, workflow tasks, and activity execution are traced (R22); the workflow-outbound interceptor chain exists (R71); the code carries seam comments at `init()` and the `%OUT_SPAN_VERB` table.

**Required behavior.** Implement the workflow-outbound tracing wrapper on the R71 chain (Python reference `../sdk-python` `contrib/opentelemetry.py` `_TracingWorkflowOutboundInterceptor`, approx. lines 751-831): wrap each outbound operation in a span named per `%OUT_SPAN_VERB` and inject trace context into the operation's headers (the pass-through Payload header contract from `Temporalio::Interceptor::Headers`).
Span creation must no-op during replay, like the rest of the interceptor.

**Acceptance.** Extend `sdk/t/unit/tracing.t` (fake-tracer scaffold in `sdk/t/lib/FakeOTel.pm`) with outbound span and header-injection assertions; drop the pending POD note.

### I12: Expose cloud, test, and health raw service handles

**What is missing.** The raw service surface (R91) exposes only `workflow_service` and `operator_service` (`Client.pm:94-95`).
Python additionally exposes cloud, test, and health services.
The plumbing is ready (`Connection::rpc_call` takes a `service =>` discriminator; `Client/RawService.pm` builds a handle from any vendored service proto) but the cloud/test/health protos are not vendored under `sdk/share/proto/` and no handle classes exist.

**Required behavior.** Vendor the missing service protos at the pinned sdk-rust tag, add one descriptor root per service in `Core/Proto.pm`, generate the handles via `RawService`, and add `cloud_service`/`test_service`/`health_service` accessors on `Client` with POD.
Confirm the c-bridge service discriminator values for each against the pinned header before wiring.

**Acceptance.** A unit test asserts each new accessor returns a handle exposing at least one expected snake_case rpc method for that service (descriptor-driven, no live RPC).

### I14: Deduplicate Duration conversion; re-verify the POSIX import

**What this is.** Two internal cleanups, neither user-visible.
1. **POSIX import.** The issue claims `Activity/Pool.pm` loads `POSIX ()` unused, but `POSIX::close` is called at `Pool.pm:499`. Re-verify: if POSIX is used, the import stays and this half is closed as not-applicable; only remove the import if it is genuinely dead.
2. **Duration conversion.** Duration-to-seconds and seconds-to-Duration logic exists in `Converter/Failure.pm` (the R74 pair `_duration_from_seconds`/`_seconds_from_duration` at :97/:103), `Common/RetryPolicy.pm`, `Workflow/Commands.pm`, and the Schedule modules.

**Required behavior.** Extract one shared Duration conversion pair into a single home (`Temporalio::Core::Proto` or a small `Temporalio::Common::Duration`, per the R74 executor's suggestion) and point every call site at it.
Pure refactor: behavior is pinned by the existing suites, no new tests beyond what already covers each call site.

**Acceptance.** `prove -lj4 t` and `prove -lj4 xt` stay green; the four Duration conversion copies become one.

### I18: Add a compile canary for two attributed classes per file

**What this is.** Two attribute-bearing classes in one `.pm` fail to compile once Future::AsyncAwait is loaded (a core-perl 5.38+ parser-state bug widened by F::AA, documented in `.ai-sessions/lessons.md`).
The SDK routes around it (one attributed class per file) and there is no user-facing breakage.

**Required behavior.** Add a TODO/xfail unit test (eval-string style, in `sdk/t/unit/attribute_handlers.t`) that asserts two attributed `:isa` classes in one file should compile.
It is expected to fail today; mark it TODO so the suite stays green, and when a future perl or F::AA fixes the parser state it flips to passing and flags that the one-class-per-file workaround can be relaxed.
Do not attempt an SDK-side fix; the real fix is upstream.

**Acceptance.** The suite stays green with the new test marked TODO; the test carries a comment pointing at the lessons.md entry and this issue.

## Component Boundaries

- **Runner (`Workflow/Runner.pm`)**: I2 (signal dispatch funnel), I1 (evict handler/conditions sweep), I9 (dynamic update validator fallback). Three independent sites; land as three steps.
- **Worker lifecycle (`Worker.pm`, `Test/Worker.pm`)**: I3 (run unwind + poll drain), I5 (test-helper wedge diagnostic). Independent.
- **Schedule (`Schedule/Action.pm`)**: I4 (decode round-trip).
- **Client / WorkflowHandle (`Client/WorkflowHandle.pm`, `Client.pm`)**: I8 (start_update result_type), I11 (fetch_history), I13 (count_workflows POD), I12 (raw service accessors).
- **Common (`Common/Priority.pm`)**: I10 (priority_key guard).
- **Pool + activity context (`Activity/Pool.pm`, `Worker/ActivityDispatcher.pm`, `Activity/Context.pm`, possibly `ext:`)**: I7 (heartbeat chain + cancellation_details).
- **OTel (`Contrib/OpenTelemetry/TracingInterceptor.pm`)**: I6 (workflow-outbound spans).
- **Cleanup (`Activity/Pool.pm`, `Converter/Failure.pm`, `Common/RetryPolicy.pm`, `Workflow/Commands.pm`, `Core/Proto.pm`)**: I14. **Canary (`t/unit/attribute_handlers.t`)**: I18.

## Verification

Every step lands one green commit. The goal condition per step: the repo gate `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )` exits 0, and where the step touches POD, `prove -lj4 xt` exits 0.
I7 if it touches `ext:` also runs `cargo test` and the Alien rebuild under the memory guard.
The full 15-issue closeout is done when all steps are checked in `todo.md`, the suite is green, and each fix's issue can be closed with its landing commit.

## Review Record

Spec written 2026-09-11 from the 15 open issues (#1-#14, #18) after archiving the R1-R97 cycle to `.ai-sessions/r1-r97-remediation/`.
Source detail confirmed by inspecting each cited file at current `main` (commit 55816a1).
One issue premise corrected during inspection: I14's "unused POSIX import" is stale (`POSIX::close` is live at `Pool.pm:499`); the step re-verifies before removing.
