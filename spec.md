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

**Required behavior.** A die in a sync signal handler is classified exactly like a die escaping the main `:Run` body (`_outcome_for_failure` / `_is_workflow_failure_exception`, `Workflow/Runner.pm:4107-4126`): a `Temporalio::Exception::*` (or a class listed in `workflow_failure_exception_types`) fails the workflow EXECUTION (`FailWorkflowExecution`), matching Python's `workflow_is_failure_exception` -> `_set_workflow_failure` (`../sdk-python temporalio/worker/_workflow_instance.py:2560-2562`); any other (plain or foreign) die fails the workflow TASK, matching Python's `_current_activation_error` route (`:2563-2565`).
Route the failed signal-handler future into the same die-to-failed-completion funnel R11 built (`Worker/WorkflowDispatcher.pm` catch-all).
Confirm the async `:Signal` path (already tracked through `%in_progress_handlers`) already reports; if it does not, fix it in the same step.

**Acceptance.** A replay test delivers a signal whose handler dies with a plain exception and asserts a failed WFT completion is produced instead of a normal completion; a second replay test delivers a signal whose handler throws a `Temporalio::Exception::Application` and asserts a `FailWorkflowExecution` command instead.

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

## Frontier Review Remediation (F1-F15)

**Origin.** After all fifteen issue-closeout steps landed (I1-I14, I18, one commit each on `issue-closeout`), fifteen independent read-only reviews on Fable 5.1, one per commit, returned four NEEDS FIX and eleven SHIP WITH NITS verdicts.
The orchestrator verified every block against the code before writing this section.
This section turns those reports into fifteen remediation steps, blocks first.
The bar is unchanged: Temporal-spec semantics first, Python parity (`../sdk-python`) as ground truth, reproduce-first tests, one green commit per step.

**Verification command:** `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )` plus `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )`.

### F1: OTel workflow-outbound headers must be real Payloads end to end (block, from I6)

`_carrier_to_payload` in `Contrib/OpenTelemetry/TracingInterceptor.pm` returns an unblessed `{metadata, data}` hashref.
Every Runner root passes outbound headers through `Temporalio::Interceptor::Headers::to_payload_map`, whose `is_payload` requires a blessed Payload, so the hashref is JSON-encoded as a payload body (double wrap).
On the inbound side the dispatcher threads blessed wire Payloads into the input and `_payload_to_carrier` requires `ref eq 'HASH'`, so it extracts nothing.
The I6 linkage test passes only because it hands the raw hashref from outbound straight to inbound.
Required: build the header as a blessed `Temporalio::Payload`; duck-type the extractor on `metadata`/`data`; prove the round trip through a real Runner via the replay harness by decoding the emitted `ScheduleActivity.headers` once and recovering `traceparent`; assert each traced op injects its own span's context, not the parent's; cover the parent-missing gate and `always_create_workflow_spans` on the outbound side.

### F2: Signal-handler failures must share the body's full classification (block, from I2)

`Runner::_settle_signal` implements only the last two branches of `_outcome_for_failure`.
On workflow cancel the Runner fails parked futures with `Temporalio::Exception::Cancelled`, which is a Temporal exception, so a parked async `:Signal` handler now claims the one-shot terminal slot with FailWorkflowExecution before the body can emit CancelWorkflowExecution: a regression against the pre-I2 tree.
Continue-as-new raised from a handler and Nondeterminism are misrouted the same way.
Required: one ordered classifier (evicting, continue-as-new, cancel-requested plus Cancelled, Nondeterminism, workflow failure, task failure) consumed by both the body path and handler settlement (Python `_run_top_level_workflow_function`, `_workflow_instance.py:2518-2565`); an evicting guard so settlement during `evict` emits nothing (Python `_deleting`); re-partition state-mutating commands when a handler emitted the terminal command; replace the thirteen em-dashes I2 added.

### F3: A dead poll loop must keep draining until core shuts down (block, from I3)

`Worker::run` now races loops to first failure, initiates shutdown, and finalizes, but the failed loop stops polling.
Core's shutdown waits for pending evictions and in-flight activity cancels to be polled and replied to, so a dead workflow loop with cached runs, or a dead activity loop with an in-flight body, wedges `_finalize_and_free` (lessons.md line 14 records this deadlock).
Python replaces the failed poller with `drain_poll_queue` on that kind (`_worker.py:846`, `_activity.py:190`, `_workflow.py:231`).
Required: per-kind drain of the dead loop's queue, completing each task with a failed "Worker shutting down" completion until the poll returns shutdown; await the dead loop's in-flight dispatches before finalize; a reproduction that caches a run before injecting the workflow-poll failure; integration assertions on post-run state and on the absence of a secondary error.

### F4: The two-classes canary must be able to flip, and its claims must be true (block, from I18)

The canary wraps a `T2->subtest` inside `T2->todo`, so the top-level line is `ok 5 # TODO` today and after an upstream fix alike; the harness cannot distinguish them.
The commit body, the upstream-report draft, and a new lessons.md entry claim the shape reproduces without Future::AsyncAwait; it does not (the probe loaded `Temporalio::Workflow`, which uses Future::AsyncAwait at line 8), and the eval-string form does reproduce.
Required: TODO scoped to the inner assertions only; a non-TODO `like` on the exact error text so a wrong-reason failure cannot mask a flip; the lessons entry corrected (fold into the 2026-07-10 entry); a corrected, self-contained upstream-report draft (no SDK dependency, Future::AsyncAwait required, expected versus actual, negative controls) recorded in the session summary since the earlier commit body is immutable.

### F5: Vendored cloud, test, and health protos must come from the pinned tag (block, from I12)

The v0.4.0 tag holds all four trees under `crates/common/protos/`; the orchestrator checked the post-tag `crates/protos/protos/` path and concluded wrongly that the tag predates them.
Eighteen of nineteen vendored files are byte-identical to the tag; `connectivityrule/v1/message.proto` carries a post-tag field the installed 0.4.0 bridge silently drops.
Eager parsing of the cloud tree adds roughly a third to every client's proto load time.
Required: re-vendor from the tag path (byte-identical, connectivityrule reverted); correct the lessons entry, the test header, and the session record; a test that pins the service codes 3, 4, 5 and one response class; lazy loading of the cloud and test trees if `Protobuf::Schema` accepts files after the first resolve, otherwise the cost documented in POD.

### F6: Fork-pool frame pairing must be token-exact (warn, from I7)

A late cancel frame for a finished token writes its details into the next invocation's holder on the same child; an `hbd` sent before a failed encode can pair with a later `hb`; a chain that dies still records the heartbeat where the async path records nothing; the race test cannot distinguish the final fix from the rejected `%token_conn` guard.
Required: guard the holder write by token; send `hbd` only after the encode succeeds or tag both frames with a sequence; drop the heartbeat on chain failure and fix the Python citation; a hold-at-accept race variant; a parity assertion on `is_worker_shutdown`.

### F7: Dynamic update validators must be honored on every path (warn, from I9)

An `:UpdateValidator` declared by attribute for a dynamic `:Update` method is never wired into `{dynamic}{update_validator}`; the Runner never invokes the inbound chain's `validate_update`; the no-fallback rule and install/uninstall symmetry are untested; a validator returning a pending Future is silently accepted.
Required: attribute wiring, chain routing under the same read-only depth (Python `_workflow_instance.py:650`), a pending-Future guard, and the missing tests; POD reword away from "fallback".

### F8: Eviction must settle handlers silently (warn, from I1)

A condition-parked update or signal resumes with Cancelled during `evict` and runs the failure converter and terminal-command path on a runner being torn down; a converter that dies would escape `evict`.
Required: the evicting guard from F2 applied to update settlement too; a test for a wait_condition-parked `:Signal` under evict; a cancel counter and a weakened runner reference in the existing test; the sweep-order invariant stated in the comment; a "tasks remain" tripwire noted as a follow-up issue.

### F9: Schedule Action decode must not drop what it cannot type (warn, from I4)

Search attributes without recognized type metadata are dropped on decode, so describe-modify-update strips them; Python keeps an untyped residual and re-sends it.
Required: carry an untyped residual on the action and re-encode it on update, or document the limitation in POD if spec section 7.4 forbids it; `metadata // {}` guard; `decode_value` skips on decode failure; RetryPolicy proto3 defaults on hand-built protos; a `_to_proto(_from_proto(x))` byte-identity test and a wire-crossing round trip covering every indexed value type.

### F10: The shared Duration pair must round correctly (warn, from I14)

Negative fractional seconds lose one nanosecond; a fraction within half a nanosecond of the next second yields nanos of one billion.
Both are inherited from the eight old copies.
Required: sign-aware rounding with carry, tests for negative, overflow, string input, NaN and Inf, and the jitter zero-to-undef fold; fix the Spec.pm comment that points at a deleted scratch file.

### F11: fetch_history must be proven to page (warn, from I11)

No test anywhere exercises multi-page history paging, and the option pass-through subtest discards the captured calls.
Required: a two-page responder asserting the second request carries the first token and all events arrive in order; assertions on page_size, a non-default event_filter_type, and skip_archival; a POD sentence on run_id pinning after continue-as-new.

### F12: Test::Worker shutdown must leave the real run future alive and observed (warn, from I5)

The wedge test never asserts the real run future survives the timeout uncancelled, so a cancel-detecting non-shield would pass; the abandoned run future has no continuation, so a late failure is lost.
Required: the missing assertion; an `on_ready` retention with diag; the contract comment qualified; the stale `await_result` POD fixed; the todo wording aligned.

### F13: result_type must be proven to reach the converter (warn, from I8)

No test hands a hint-sensitive converter to the client, so a handle that stores the type but never applies it passes.
Required: a recording payload converter asserting the hint on both `start_update ... ->result` and `execute_update`, including the polling branch; POD on the handle naming both constructors; stale line anchors removed; interceptor `opts` keys documented.

### F14: Priority must reject what the wire cannot carry (warn, from I10)

The guard has no upper bound, so values above int32 pass construction and die later with the codec's OutOfRange class; overloaded objects pass every clause.
Required: an int32 upper bound and a `ref` rejection in the guard, the comment widened to what the guard actually accepts, and tests for 2**31, an overloaded object, and the string form round trip.
The sibling `fairness_weight` guard also rejects references, closing the same hole in the same shape.

### F15: count_workflows POD must be pinned by its test (nit, from I13)

The test's aggregation groups carry empty group_values, so the documented raw-Payload shape is asserted nowhere.
Required: one group with a Payload and an isa assertion; POD naming the public single-payload decode accessor and stating that `$query` may be omitted.
