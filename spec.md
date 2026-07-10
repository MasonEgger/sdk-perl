# sdk-perl Remediation Specification

## Overview

This repository has no root *implementation-contract* spec.md; the v1 contract is archived at `.ai-sessions/v1/spec.md`.
This document, `spec.md` at the repository root, is a remediation and feature-parity spec, not that contract.
The contract it holds the code to is reconstructed from three sources.
First, the archived v1 spec, whose prime directive (spec §0) is Temporal-spec semantics first, Perl idioms second: any behavior consistent across two or more reference SDKs is the de facto contract.
Second, the live-hardening phase docs: the root `plan.md`/`todo.md`, the 11-bug field report `sdk-perl-issues-from-samples.md`, and `ROOT-CAUSE-MAP.md`.
Third, the shipped API surface as mapped in the step-43 state note (`../../.ai-sessions/step-43-sdk-perl-state.md` relative to this repo; the portfolio-level `.ai-sessions/` under `~/Code`).
Where those sources are silent, the sibling checkout `../sdk-python` is the semantics ground truth, per §0 and the repo CLAUDE.md.
The bar for this repository: feature-complete parity with the reference SDKs (`../sdk-python` first), so a Perl developer can build on this SDK against documented behavior and reach for any capability the reference SDKs expose.
A method whose POD promises spans, codec coverage, or cancellation delivery that the code does not perform fails that bar even when the suite is green; so does a capability the reference SDKs ship that this SDK lacks.

A multi-agent portfolio review on 2026-07-02 produced candidate findings against the v0.2.0 tree (branch v1, commit 4994ba6).
Adversarial verification (step 45, `../../.ai-sessions/step-45-sdk-perl-verified.md`) confirmed 68 unique defects with exact file and line references, refuted 1 candidate, refuted 4 sub-claims inside confirmed items, and surfaced 2 adjacent defects while re-running probes.
This spec defines the required behavior for all 70: the 68 confirmed findings plus the two adjacent ones (ADJ1, ADJ2).
R71 onward add the reference-SDK feature-parity requirements from a 2026-07-06 audit (see Feature Parity below); together they carry the SDK to feature-complete parity, not just defect-free.

Citation convention, matching the step-45 note: module paths are relative to `sdk/lib/Temporalio/`; the `ext:` prefix means `ext/temporalio-perl-bridge/src/lib.rs`; `t/` and `xt/` paths are under `sdk/`.
Each requirement names its step-45 finding id in parentheses.
Eleven findings were confirmed by code analysis rather than an executed probe (L1, L2, L3, L7, L8, L10, L13, L15, L16, L18, R12); their acceptance criteria follow Global Requirement 5.
Probe artifacts from the verification live in the session scratchpad (`scratchpad/verify-45/`), which is ephemeral; every requirement that cites a probe requires committing an adapted version into `sdk/t/` as the reproduce-first test.

## Scope

In scope: the 70 defects below, their reproduce-first tests, the POD or README corrections a fix requires, and the feature-parity work needed to bring this SDK to feature-complete parity with the reference SDKs (`../sdk-python` first).
Refactors are in scope when a fix or a parity gap needs one, but each must be scoped as its own requirement so it can be planned and estimated accurately, not left open-ended.
Parity gaps not already covered by R1 through R70 are enumerated as additional requirements (R71 onward) from a reference-SDK audit; that audit landed on 2026-07-06 and its gaps are enumerated as R71 through R97 below, so the requirement body is complete.
Out of scope: the refuted candidate L27 (see Review Record) and samples-perl fixes (tracked in that repo's own remediation spec; nothing here changes samples-perl).

Severity triage used for ordering:

- High (R1 through R7): memory corruption across the FFI boundary, cross-worker state clobbering, wire-format corruption, or a silently defeated encryption boundary.
- Medium-high (R8 through R21): core workflow semantics wrong under cancellation or failure, permanently wedged workflow tasks, live/replay divergence, stranded completions.
- Medium (R22 through R38): documented features that do not function, resource leaks and fd hygiene, backpressure and validation gaps, flaky test infrastructure.
- Low-medium (R39 through R49): missing or dead test coverage, unreachable diagnostics and retry branches, teardown hygiene.
- Low (R50 through R70): doc and POD drift, error-typing polish, cross-SDK parity edges, comment fixes.
- Feature parity (R71 through R97): reference-SDK capability gaps from the 2026-07-06 audit, banded High, Medium, and Low by blast radius.

## Available Tooling

Tools the `bpe:validator` agent should consult when reviewing diffs in `/bpe:goal` runs.
`/bpe:plan` propagates these to per-section declarations in plan.md.

**MCPs:**
- mcp__temporal-docs__search_temporal_knowledge_sources (activation protocol, cancellation types, codec boundaries, update/query semantics, replay contracts)

**Skills:**
- temporal:temporal-developer

**Repo gates:**
- `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 PATH=$HOME/.local/bin:$PATH prove -lj4 t )` for the unit/replay/integration suite; integration files `skip_all` without a dev server.
- `( cd sdk && PERL5LIB=$HOME/perl5/lib/perl5 prove -lj4 xt )` for author tests (POD syntax and coverage).
- `( cd ext/temporalio-perl-bridge && cargo test )` for the Rust shim; `dzil test` per distribution.
- Every cargo, Alien, or dzil build follows the CLAUDE.md memory guard: `CARGO_BUILD_JOBS=2` (retry once at 1 on an OOM or signal death), foreground only, generous timeout; never background a build.
- Any change to `ext:` follows the shim protocol: `cargo test`, regenerate the cbindgen header, rebuild the installed `Alien::Temporalio::PerlBridge` (the P0.10 precedent).

**Notes:** validator should hold every diff to §0 parity, verifying MUST-match semantics against the sibling checkouts (`../sdk-python` first), not from memory.

## Global Requirements

These apply to every requirement below.

1. **Contract sources.** Required behavior derives from the archived v1 spec, the live-hardening docs, and reference-SDK parity, in that order.
   "Python parity" in a requirement means the behavior is verified against `../sdk-python` source at implementation time.
2. **Gates.** The full prove suite (t and xt), and for shim-touching changes cargo test plus the Alien rebuild, pass after every requirement, under the memory guard.
3. **Test-first.** Each behavior fix starts with a failing test that reproduces the defect.
   Prefer replay tests (`t/replay/`, offline) over integration tests; integration tests `skip_all` without a dev server.
   Where a step-45 probe exists, the RED step is that probe adapted into a committed test; the scratchpad originals do not survive the session.
4. **POD in the same change.** A fix that alters public behavior updates the POD in the same commit; `xt` pod coverage stays green.
5. **Memory-safety criteria convention.** Where the defect is a race, use-after-free, or fork-timing hazard that a test cannot execute deterministically, the acceptance criterion is threefold: the guard exists in code; a committed test asserts the guard's observable ordering or presence (for example, barrier invoked before free, guard flag checked before the FFI call); and the test's comments carry the code trace citing the involved lines.
   No memory-safety fix is accepted on analysis alone without that encoded assertion.
6. **No behavior drift.** Fixes change only the defective behavior; the v0.2 feature surface stays intact.
7. **Public prose.** POD and README edits follow the repo writing rules: no em-dashes or en-dashes, straight quotes, plain voice.
8. **Cross-fix coherence.** Requirements marked as clustered (memory safety R1 through R3, the post-cancel family R8 through R10) land with shared tests where noted, so one story covers the cluster.

## Requirements

### High

R1 through R3 form the memory-safety cluster: three lifetime races between Perl-side frees and core-side borrows across the FFI boundary.
All three are analysis-confirmed (the race window is not deterministically executable from a test), so all three carry Global Requirement 5 criteria.
Two more memory-safety items sit lower in the ordering because their blast radius is smaller: R28 (COW buffer corruption, probe-executable) and R16 (freed-value iteration, probe-executable).

### R1: Add a Drain Barrier to Runtime Shutdown (High)

**Defect.** `Runtime.pm:252-253` frees the shim completion queue during shutdown while async bridge calls may still be in flight; the shim side (`ext:1684-1689`, `ext:206-227`, `ext:368-392`) can then complete a callback into a freed queue.
There is no barrier that waits for in-flight completions before the free.
(Finding L1, analysis.)

**Root cause.** Shutdown ordering assumes quiescence instead of enforcing it.

**Required behavior.** Runtime shutdown must not free the completion queue until no outstanding async bridge call can still deliver a completion.
Implement a drain barrier: a count or registry of outstanding callbacks that shutdown waits on (with the existing eventfd drain) before invoking the free.

**Acceptance criteria.**
- The barrier exists and is invoked on every shutdown path before the queue free (code-trace assertion per Global Requirement 5, citing `Runtime.pm:252-253` and the `ext:` trampoline paths).
- A unit test drives shutdown with a synthetically registered outstanding callback and asserts the free is deferred until the callback resolves or is failed.
- `cargo test` covers any shim-side counterpart under the shim protocol.

**Test notes.** Coordinate with R21: the same shutdown pass must also fail `$pending` futures, and one shutdown-ordering test can assert both.

### R2: Guard Connection Free Against a Dead Runtime (High)

**Defect.** `Client/Connection.pm:50-66` (close and DESTROY) calls `client_free` (`Core/FFI.pm:606-608`) with no runtime-liveness check; if the owning runtime has already shut down, the free runs against a torn-down core and is a use-after-free.
(Finding L2, analysis.)

**Root cause.** Connection lifetime is not tied to runtime lifetime; destruction order is left to Perl global destruction.

**Required behavior.** A connection either holds a strong reference that keeps the runtime alive until `client_free` completes, or checks runtime liveness and skips the FFI free (releasing only Perl-side state) when the runtime is gone.

**Acceptance criteria.**
- The guard exists on both the close and DESTROY paths (code-trace assertion per Global Requirement 5).
- A unit test destroys the runtime first and then the connection, and the process neither crashes nor calls `client_free` (spy or logging assertion on the FFI call).

**Test notes.** Global-destruction ordering is the hard case; the test should exercise both explicit-close-after-shutdown and DESTROY-after-shutdown.

### R3: Stop Freeing the DevServer Handle on the Timeout Path (High)

**Defect.** `Test/DevServer.pm:232` frees the dev-server handle (`Core/FFI.pm:625-628`) on the shutdown-timeout path while core still borrows the handle for the in-flight shutdown call; the late completion then touches freed memory.
(Finding L3, analysis.)

**Root cause.** The timeout arm treats an unresolved bridge call as abandoned when core still holds the pointer.

**Required behavior.** The timeout path must never free a handle core may still borrow.
Either defer the free to a continuation on the still-pending bridge future, or deliberately leak the handle on timeout with a logged warning.

**Acceptance criteria.**
- No code path frees the handle while the shutdown bridge future is pending (code-trace assertion per Global Requirement 5).
- A unit test forces the timeout arm (mock or stalled future) and asserts the free is deferred or skipped.

**Test notes.** Related but distinct from R46 (the `$is_shutdown` flag order) and R33 (abandoned futures leaking the CLI); one DevServer shutdown test file can host all three cases.

### R4: Make Activity Pool State Per-Instance, Not Process-Global (High)

**Defect.** `Activity/Pool.pm:29-38, 71-75, 150-151`: the ADJUST block publishes the activity registry, FD list, and module list into process-wide `main::` package globals.
A second worker's pool construction clobbers the first pool's globals before its children fork; the step-45 probe had pool A executing pool B's registry.
(Finding L12, probe `verify-45/pool-payload/probe_pool_globals.pl`.)

**Root cause.** Fork-time state hand-off uses package globals instead of per-instance data captured by the child closure.

**Required behavior.** Each pool's children read that pool's own registry, FD list, and module list, regardless of how many workers exist in the process.
Pass the state per-instance (closure capture, init args, or keyed storage), not via shared globals.

**Acceptance criteria.**
- A prove test constructs two pools with distinct registries in one process and asserts a dispatch through pool A executes pool A's activity (the committed adaptation of the probe).
- No `main::` globals remain in `Activity/Pool.pm` for registry, FD, or module hand-off (grep probe).

**Test notes.** Land together with R5 and R19; all three rework the parent-child channel in `Activity/Pool.pm`.

### R5: Preserve Error Identity Across the Pool Fork Boundary (High)

**Defect.** `Activity/Pool.pm:187` and `:130` stringify child exceptions, and `Worker/ActivityDispatcher.pm:307-314` rewraps the string as a generic retryable ApplicationError.
A sync activity that throws a non-retryable `Temporalio::Exception::Application` comes back retryable, so a permanently failing activity retries forever.
(Finding L14, probe `verify-45/pool-payload/probe_pool_error.pl`.)

**Root cause.** The fork channel carries only a message string, not structured error data.

**Required behavior.** Exception class, error type, `non_retryable`, details, and the cause chain survive the fork boundary, so the dispatcher rebuilds the original failure semantics.
Serialize structured error data across the channel (the failure converter shape is the natural carrier).

**Acceptance criteria.**
- A prove test throws a non-retryable ApplicationError from a pooled sync activity and asserts the parent-side failure is non-retryable with the original type and details (committed probe adaptation).
- A plain die still maps to a retryable ApplicationError with the message intact.

**Test notes.** Python parity for the rebuilt failure shape; verify against `../sdk-python` activity failure handling.

### R6: Fix Wide-Character Corruption in RawBytes at the FFI Boundary (High)

**Defect.** `Payload/RawBytes.pm:13-18` accepts a UTF8-flagged wide-character scalar; `Core/FFI.pm:522-527` then mixes character-semantics lengths with UTF-8 byte buffers, and the proto framing disagrees with the payload (probe measured 34 versus 36 bytes).
Corrupted frames cross the wire silently.
(Finding L21, probe.)

**Root cause.** No byte-purity enforcement at the payload boundary; Perl's dual string representation leaks into FFI length math.

**Required behavior.** RawBytes either downgrades/encodes input to bytes deterministically or rejects wide-character scalars with a typed error.
Whatever the choice, the byte length used for framing equals the bytes actually written, always.

**Acceptance criteria.**
- A round-trip test with a wide-character scalar either passes with matching frame and payload lengths or raises the documented typed error; no silent mismatch.
- A latin-1-range UTF8-flagged scalar (the ambiguous case) round-trips byte-identically.

**Test notes.** Check every `scalar_to_buffer` call site in `Core/FFI.pm` for the same hazard while in the file; R28 covers the COW variant.

### R7: Extend the Payload Codec Boundary to the Full v0.2 Surface (High)

**Defect.** The codec boundary in `Worker/WorkflowDispatcher.pm:200-249` and `:170-181` covers only the v0.1 surface.
Update input, child and nexus results, failure payloads, memo and headers, update and query responses, continue-as-new args, local-activity args, signal-external args, and upserts all bypass the codec, so a configured encryption codec is silently defeated on those paths.
(Finding R6.)

**Root cause.** The codec wiring was written for the v0.1 activation surface and never extended as v0.2 features landed.

**Required behavior.** Every payload that crosses the worker boundary passes through the configured codec in both directions, matching the Python codec boundary.
Search attributes stay excluded: the step-45 verification confirmed Python also keeps SAs codec-free (see Review Record, sub-claim 1).

**Acceptance criteria.**
- Replay tests with a marker codec (one that tags every payload it touches) assert encode on every outbound surface listed above and decode on every inbound one.
- The same tests assert search-attribute payloads are not codec-wrapped.
- The codec section of the Converter POD lists the covered surfaces.

**Test notes.** This is the largest single requirement; drive it surface-by-surface with one replay test per surface so a regression pinpoints the path.

### Medium-High

R8 through R10 are the post-cancel corruption cluster (the R4 finding family): three ways the runner destroys a workflow that tries to do anything after receiving a cancel.
Their reproduce-first tests are the step-45 probes adapted into `t/replay/`; R40 tracks the coverage debt for the surrounding arms.

### R8: Let Post-Cancel Cleanup Work Run to Completion (Medium-High)

**Defect.** A workflow that catches Cancelled and awaits a cleanup activity is killed by the main-run-future fallback.
The AWAIT_CLONEd `_ActivityFuture` (`Workflow/Runner.pm:1709`) is swept by the fallback cancel at `:2276-2278`, which fails the run mid-await; with ScheduleActivity and CancelWorkflowExecution arriving in one completion, the later activity resolution dies "already failed and cannot be ->done" (`:3297-3306`).
(Finding R4, probe re-run.)

**Root cause.** The cancel fallback fails the main run future unconditionally instead of delivering cancellation into the awaited point and letting the body continue.

**Required behavior.** Python parity: workflow cancel raises Cancelled at the awaited point; a body that catches it may schedule and await new work (cleanup activities, timers), and that work completes normally before the workflow closes.
The fallback must not fail the main run future while the body is alive and awaiting post-cancel work.

**Acceptance criteria.**
- A replay test drives ScheduleActivity plus CancelWorkflowExecution in one activation, has the body catch Cancelled and await a cleanup activity, and asserts the cleanup activity's command is emitted and its resolution completes the workflow.
- The "already failed and cannot be ->done" death is gone from that path.

**Test notes.** Reproduce-first: adapt the step-45 R4 probe into `t/replay/` (the scratchpad `verify-45/cancel-core/` harness pattern with `WfDef` modules and pushed activations is the template).
Commit the test before the fix as the RED step.

### R9: Fix the Plain-Future Arm of the Cancel Fallback (Medium-High)

**Defect.** When the main run future is a plain Future, the cancelled future takes the success branch and `->result` croaks at `Workflow/Runner.pm:2851`; the activation dies and no completion is sent.
(Finding R4b, probe.)

**Root cause.** The completion builder does not discriminate the cancelled state before calling `->result`.

**Required behavior.** A cancelled main run future maps to the cancelled workflow outcome (matching the outcome table), never to a croak in `_build_completion`; the activation always produces a completion.

**Acceptance criteria.**
- A replay test parks the body on a plain Future, delivers `cancel_workflow`, and asserts a completion with the CancelWorkflowExecution outcome is produced (no die, no missing completion).

**Test notes.** Same reproduce-first template as R8; the scratchpad probe `verify-45/cancel-core/probe_r4bc_ext_signal.t` exercises this arm via the external-signal wait and adapts directly into `t/replay/`.

### R10: Sweep Pending External Signals and Cancels on Workflow Cancel (Medium-High)

**Defect.** `_apply_cancel_workflow` (`Workflow/Runner.pm:2188-2278`) never sweeps `%pending_external_signals` or `%pending_external_cancels` (populated at `:934`, `:994`, `:2009`), so a body parked on an external-signal or external-cancel future never observes cancellation.
(Finding R4c, probe `verify-45/cancel-core/probe_r4bc_ext_signal.t` with `WfDef/ExtSignalWait.pm`.)

**Root cause.** The cancel sweep enumerates the other pending maps and misses these two.

**Required behavior.** Workflow cancel fails pending external-signal and external-cancel futures with Cancelled, exactly as it does the activity, timer, and child maps, so a parked body wakes and can run its Cancelled path.

**Acceptance criteria.**
- The committed adaptation of the R4c probe passes: body parked on `signal_external_workflow_execution`, `cancel_workflow` delivered, body observes Cancelled and returns, completion produced.
- The same shape passes for the external-cancel map.

**Test notes.** Reproduce-first: the probe currently dies inside `push_activation`; the committed test's RED state is that die.

### R11: Always Send a Completion for a Failed Activation (Medium-High)

**Defect.** There is no catch-all around activation processing: `Worker/WorkflowDispatcher.pm:89-128` lets dies escape and `Worker/PollLoop.pm:46-50` warns and swallows them, so the workflow task is never completed and the workflow wedges until timeout, forever on each retry.
Verified trigger sites include `Workflow/Runner.pm:2687, 2572, 1839, 1914, 2080-2081, 2151-2152, 2851`.
Python always sends a failed completion.
(Finding R5, equal to L9; probe `verify-45/cancel-core/probe_r5_async_query.t`.)

**Root cause.** Error handling stops at logging; the completion contract with core is not honored on the failure path.

**Required behavior.** Any die during activation processing produces a failed workflow-task completion (or eviction, per the core activation contract), never a swallowed warn.
Python parity for what goes into the failure.

**Acceptance criteria.**
- A replay test with a `:Query` handler returning a pending future (the probe scenario) asserts a failed completion is sent instead of an unhandled die.
- A fault-injection test (a workflow that dies inside a handler the runner mishandles) asserts the WFT fails rather than wedges.

**Test notes.** This requirement converts several R-family dies from process hazards into reported failures; land it after R8 through R10 so their RED tests fail for the right reason first.

### R12: Honor WAIT_CANCELLATION_COMPLETED for Regular Activities (Medium-High)

**Defect.** `Workflow/Runner.pm:513-537` fails the activity future immediately on cancel even when the caller asked for WAIT_CANCELLATION_COMPLETED, and the eventual core resolution is dropped as stale (`:3297-3306`, `:1739`).
Local activities honor the wait type (`:696-716`); regular activities do not.
(Finding R7.)

**Root cause.** The regular-activity cancel arm was written for TRY_CANCEL semantics only.

**Required behavior.** With WAIT_CANCELLATION_COMPLETED, the activity future resolves only when core reports the final resolution, carrying the real outcome (cancelled, completed, or failed), matching the local-activity arm and Python.

**Acceptance criteria.**
- A replay test cancels a WAIT_CANCELLATION_COMPLETED activity and asserts the future stays pending until the resolution job arrives, then resolves with the delivered outcome.
- TRY_CANCEL behavior is unchanged.

**Test notes.** Pairs with R52 and R53 (the LA wait-type edges) for one cancellation-type test file.

### R13: Keep Query and Update Responses on Failure Completions (Medium-High)

**Defect.** `Workflow/Runner.pm:3054` clears `@commands` when building a workflow-failure completion, dropping query and update responses accumulated in the same activation; the in-code comment claiming Python does the same is false.
(Finding R9.)

**Root cause.** The failure builder conflates workflow commands (which must be dropped) with handler responses (which must not).

**Required behavior.** Query and update responses survive a failure completion; only state-mutating commands are cleared.
Python parity, and the false comment is corrected.

**Acceptance criteria.**
- A replay test fails the workflow in the same activation as a query and asserts the query response is present in the completion.
- The same for an update response.

**Test notes.** Verify the exact Python behavior in `../sdk-python` before writing the assertion; cite it in the test comment.

### R14: Route workflow_failure_exception_types to Live Runners (Medium-High)

**Defect.** `Worker.pm:459-460` misroutes `workflow_failure_exception_types` into core's workflow-TYPE field via `Worker/WorkflowDispatcher.pm:170-181`, so it never reaches a live Runner (`Workflow/Runner.pm:90`); the replay harness threads it correctly (`Test/WorkflowReplay.pm:81`), producing live/replay divergence.
(Finding A1.)

**Root cause.** An options plumbing error: the wrong key lands in the wrong constructor argument.

**Required behavior.** The option reaches live Runners exactly as it reaches replay Runners; a listed exception type fails the workflow instead of the task in both modes.

**Acceptance criteria.**
- A test constructs a live-path dispatcher and asserts the Runner receives the configured types.
- A replay test and a live-shaped test drive the same workflow die and assert the same outcome.

**Test notes.** Fix together with R15; both are the same plumbing path.

### R15: Route nondeterminism_as_workflow_fail to Live Runners (Medium-High)

**Defect.** The boolean `nondeterminism_as_workflow_fail` is likewise never passed to live Runners; the same misrouting as R14.
(Finding ADJ2, verifier discovery adjacent to A1.)

**Root cause.** Same plumbing error as R14.

**Required behavior.** The flag reaches live Runners; nondeterminism converts to a workflow failure when set, in live and replay alike.

**Acceptance criteria.**
- The R14 plumbing test also asserts this flag arrives.
- A replay nondeterminism scenario asserts the workflow-failure outcome when the flag is set and task failure when it is not.

**Test notes.** One diff with R14.

### R16: Make Evict Iteration Safe Against Sibling Deletion (Medium-High)

**Defect.** Evict iterates `values %pending` aliased (`Workflow/Runner.pm:1532-1538`); cancel continuations that delete sibling pending entries (the wait_any sweeps at `:2199`, `:2212`) trigger "Use of freed value in iteration" and the eviction completion is never sent.
(Finding L6, probes `verify-45/runner-misc/probe_l6_freed_iteration.pl` and `probe_l6_self_delete.pl`.)

**Root cause.** Hash iteration over a structure the loop body mutates through continuations.

**Required behavior.** Evict iterates a stable snapshot (a copied key or value list) so continuations may delete any entry; eviction always completes.

**Acceptance criteria.**
- The committed adaptation of the freed-iteration probe passes: an evict whose cancel continuation deletes a not-yet-visited sibling completes without the croak and sends the eviction completion.

**Test notes.** The self-delete probe showed own-entry deletion is survivable; the sibling case is the RED test.

### R17: Settle Updates from Cancelled Handler Futures Without Croaking (Medium-High)

**Defect.** Evicting a run with an in-flight async `:Update` croaks in `_settle_update`: the cancelled handler future passes the `->failure` check empty and then `->result` croaks (`Workflow/Runner.pm:1533, 2522-2525, 2610`).
(Finding L7, analysis; Future semantics demonstrated by `verify-45/runner-misc/probe_l7_cancelled_result.pl`.)

**Root cause.** `_settle_update` handles done and failed futures but not cancelled ones.

**Required behavior.** `_settle_update` discriminates the cancelled state and settles the update accordingly (rejected or dropped per the eviction contract) without croaking.

**Acceptance criteria.**
- A replay test evicts a run holding a pending async update and asserts no croak and a completed eviction.
- A unit test on `_settle_update` (or its factored core) covers the three future states.

**Test notes.** The probe's cancelled-future state table goes into the test comments.

### R18: Relay Sync-Activity Heartbeats Live (Medium-High)

**Defect.** `Activity/Pool.pm:114-124, 172-174`: child heartbeats are relayed only after the activity body completes, so a long-running sync activity emits zero live heartbeats and dies by heartbeat timeout despite heartbeating correctly.
(Finding L13, analysis.)

**Root cause.** The fork channel is request-response; heartbeats queue behind the body's return value.

**Required behavior.** Heartbeats recorded by a running pooled activity reach core while the body runs, within a bounded relay latency, so heartbeat timeouts and cancellation-by-heartbeat work for sync activities.

**Acceptance criteria.**
- A prove test runs a pooled activity that heartbeats then blocks, and asserts the parent observes the heartbeat before the body returns.
- An integration test (skip_all offline) verifies a heartbeat-timeout does not fire for a compliant long-running sync activity.

**Test notes.** Requires a side channel from child to parent; design it together with R19, which needs the reverse direction.

### R19: Deliver Cancellation to Running Pool Children (Medium-High)

**Defect.** Sync-activity cancellation crosses the fork as a one-shot boolean captured at dispatch (`Worker/ActivityDispatcher.pm:280`; `Activity/Pool.pm:161-162`); a child already running never observes a later cancel.
Combined with R18, running sync activities are uncancellable.
(Finding L15, analysis.)

**Root cause.** Cancellation state is copied once instead of communicated.

**Required behavior.** A cancel arriving while a pooled activity runs is observable inside the child through the activity Context (cancellation future or `is_cancelled` polling), matching the async-activity contract.

**Acceptance criteria.**
- A prove test cancels a running pooled activity and asserts the child observes cancellation and the activity resolves cancelled (committed probe adaptation).

**Test notes.** One channel design with R18; the two-directional fork protocol is a single piece of work with two requirements attached.

### R20: Isolate Exceptions Per Entry in the Callback Drain Loop (Medium-High)

**Defect.** The completion drain loop (`Core/Callback.pm:322-331, 463-467`) has no per-entry exception isolation; one dying continuation aborts the loop and strands every later completion in the chunk.
(Finding L17, probe-verified mechanism.)

**Root cause.** A single eval would have bounded the blast radius; there is none.

**Required behavior.** Each drained entry runs under its own exception guard; a dying continuation is logged and the loop continues to the next entry.

**Acceptance criteria.**
- A unit test queues three completions where the second's continuation dies, and asserts the first and third still resolve and the error is logged.

**Test notes.** Keep the guard cheap; this loop is the hot path for every async result in the process.

### R21: Fail Pending Callback Futures at Runtime Shutdown (Medium-High)

**Defect.** `$pending` (`Core/Callback.pm:250, 472-477`) is never failed or cleared at runtime shutdown; any future awaited across shutdown hangs forever.
(Finding L18, analysis.)

**Root cause.** Shutdown tears down the delivery mechanism without settling its consumers.

**Required behavior.** Runtime shutdown fails every pending callback future with a typed shutdown error, so awaiting code gets a prompt, catchable failure instead of a hang.

**Acceptance criteria.**
- A unit test registers a pending callback, shuts the runtime down, and asserts the future fails with the shutdown error within the test timeout.

**Test notes.** Same shutdown pass as R1; one ordering test can assert barrier-then-fail-then-free.

### Medium

### R22: Implement the OpenTelemetry TracingInterceptor (Medium)

**Defect.** `Contrib/OpenTelemetry/TracingInterceptor.pm:205-233` is pure delegation: no spans are created and no context is propagated, while the POD at `:286-290` claims both.
(Finding R1, equal to A3 and L30.)

**Root cause.** The interceptor shipped as a skeleton and the POD was written for the intent.

**Required behavior.** The interceptor creates spans for client calls, workflow tasks, and activity execution, and propagates trace context through headers, as the POD promises and as the Python OTel interceptor does.
Until the implementation lands, no intermediate state may ship where the POD still overclaims.

**Acceptance criteria.**
- Unit tests with a fake tracer (the step-45 `verify-45/api-otel/fakeotel` scaffold is the template) assert span creation on each intercepted surface and header inject/extract round-trip.
- The POD matches the implemented behavior.
- samples-perl requirement R3 (the open-telemetry sample caveat) can be lifted after this lands; note it in the closing commit.

**Test notes.** R41 and R42 fix the existing tracing tests; land the three together so the test file asserts the wired behavior, not private helpers.

### R23: Make the Shared Cancellation Future Survive wait_any (Medium)

**Defect.** `Cancellation.pm:26-37` hands out a single shared `cancelled()` future guarded by `is_ready`; a `Future->wait_any` loser sweep cancels and permanently poisons it, so cancellation is never observable again.
`Activity/ChildCancellation.pm:21-34` clones the same defect.
(Finding R2, equal to A4 and L31a; probe `verify-45/cancel-core/probe_r2_wait_any.pl`.)

**Root cause.** One future object serves all consumers, and consumer-side cancel is not isolated.

**Required behavior.** `cancelled()` returns a future that consumer cancellation cannot poison: a fresh derived future per call, or a `->without_cancel` wrapper, in both classes.
The POD documents the contract so callers can race it safely.

**Acceptance criteria.**
- The committed probe adaptation races `cancelled()` in `wait_any` twice, then cancels, and asserts the second consumer observes cancellation.
- The same test shape passes for `Activity/ChildCancellation`.

**Test notes.** R50 adds the missing direct ChildCancellation coverage; supersedes samples-perl forward 2 (their R16 works around it caller-side).

### R24: Enforce Read-Only Context and Writability Asserts Uniformly (Medium)

**Defect.** `patched()`, child-signal, external-signal, and external-cancel bypass `_assert_writable` (`Workflow/Runner.pm:417-436, :929, :989-991, :1031-1033`), and query handlers never enter a read-only context at all (`:2640-2705`), so a query can emit commands.
(Finding R8, equal to L11.)

**Root cause.** The writability guard was applied per call site and the sites drifted.

**Required behavior.** Every command-emitting API asserts writability; query execution runs in a read-only context where any command emission raises the documented error, matching Python's read-only enforcement.

**Acceptance criteria.**
- A replay test drives a query handler that calls each bypassing API and asserts the typed read-only error.
- Existing writable-context behavior is unchanged.

**Test notes.** Table-drive the test across the four bypassing APIs.

### R25: Send search_attributes and versioning_intent on Continue-as-New (Medium)

**Defect.** `Workflow/Runner.pm:2933-2980` drops `search_attributes` and `versioning_intent` from the continue-as-new command despite the POD and the proto fields.
(Finding R11.)

**Root cause.** The command builder was not extended when the options were added.

**Required behavior.** Both options are carried into the ContinueAsNewWorkflowExecution command when provided; omitted options keep proto defaults.

**Acceptance criteria.**
- A replay test asserts both fields appear in the emitted command with the caller's values.

**Test notes.** Check the proto field names against the vendored trees in `sdk/share/proto/`.

### R26: Deliver Init Signals Before the Main Routine Starts (Medium)

**Defect.** Signals included in the initializing activation drain only after `:Run`'s synchronous prologue (`Workflow/Runner.pm:2317-2319, 1709, 1716`); Python runs handlers first, so signal-with-start behaves differently on Perl.
(Finding R12, analysis.)

**Root cause.** Job-application order puts start-workflow before same-activation signals.

**Required behavior.** Python parity: signal handlers for signals in the initializing activation run before the main routine's first statement.

**Acceptance criteria.**
- A replay test with signal-with-start asserts handler side effects are visible to the main routine's prologue.

**Test notes.** Confirm the exact Python ordering (signals before or interleaved per job order) against `../sdk-python` before encoding the assertion.

### R27: Install the Determinism Guard Before Workflow Code Compiles (Medium)

**Defect.** The guard is compile-order blind: `Worker.pm:139` installs it at worker construction, and `Workflow/DeterminismGuard.pm:67-69` only traps call sites compiled after installation, so normally loaded workflow modules are unguarded.
Fixable at Definition load time.
(Finding R13, probe `verify-45/runner-misc/probe_r13_compile_order.pl`.)

**Root cause.** `CORE::GLOBAL` overrides only affect subsequently compiled code, and workflow modules are typically loaded first.

**Required behavior.** Registering a workflow Definition guarantees the guard traps that workflow's `time`/`rand` call sites, regardless of load order (install at Definition load time, or require-under-guard).

**Acceptance criteria.**
- The committed probe adaptation compiles a workflow module before worker construction and asserts the guard trips inside workflow context.
- samples-perl requirement R1 (the determinism sample) becomes satisfiable without sample-side load-order tricks; note the cross-repo dependency.

**Test notes.** Design together with R38 (uninstallability); both touch the override lifecycle.

### R28: Stop Writing Through a COW-Shared Tag Buffer (Medium)

**Defect.** The 1-byte tag slot (`Core/Callback.pm:362-363`; `Worker/SlotSupplierRegistry.pm:69-70`) is a copy-on-write buffer sharing its PV with the `"\0"` literal; the shim write (`ext:868`) corrupts every COW sibling silently.
(Finding L4, probe `verify-45/memsafe-infra/cow_tag.pl`.)

**Root cause.** A string literal assigned to a scalar is COW on modern perls; `scalar_to_buffer` exposes the shared PV to a foreign write.

**Required behavior.** Every buffer handed to the shim for writing is a private, non-COW allocation (force a copy before `scalar_to_buffer`).

**Acceptance criteria.**
- The committed probe adaptation asserts a shim write through the tag slot leaves an independently created `"\0"` scalar untouched.
- An audit note in the test lists the checked `scalar_to_buffer` write sites.

**Test notes.** Memory-safety, probe-executable: the ordinary test path applies, no Global Requirement 5 fallback needed.

### R29: Break the Start-Future Ownership Cycle in Handles (Medium)

**Defect.** `Workflow/ChildWorkflowHandle.pm:58` and `Workflow/NexusOperationHandle.pm:64` resolve the start future with the owning handle itself (`Workflow/Runner.pm:895-897`), creating an uncollectable cycle that pins the handle, its futures, and the Runner per child or nexus start.
(Finding L5, probe `verify-45/runner-misc/probe_l5_cycle.pl`.)

**Root cause.** A future holds its result strongly, and the result holds the future.

**Required behavior.** Handle start futures do not create uncollectable cycles: weaken the back-reference or resolve with a non-owning token that callers exchange for the handle.

**Acceptance criteria.**
- The committed probe adaptation asserts the handle's DESTROY runs after use (weak-ref liveness check) for both handle classes.

**Test notes.** Watch for the same shape anywhere else a future resolves with its owner.

### R30: Close Inherited gRPC Descriptors in Pool Children (Medium)

**Defect.** Pool children inherit all core and client gRPC socket fds (`Worker.pm:633`; `Activity/Pool.pm:49-56`); the architecture rule (repo CLAUDE.md) says children must close inherited FDs, and they do not.
(Finding L16, analysis.)

**Root cause.** The fork setup never enumerates core-owned descriptors.

**Required behavior.** Children close every inherited core/client descriptor immediately after fork, keeping only the pool channel fds.

**Acceptance criteria.**
- A prove test forks a pool child and asserts (via `/proc/self/fd` or fd counting) that core/client sockets are closed in the child while the pool channel stays open.

**Test notes.** Linux-specific fd enumeration is acceptable with a skip on other platforms.

### R31: Honor Pending Futures from Custom Slot Suppliers (Medium)

**Defect.** A custom slot supplier returning a pending Future gets a fabricated instant permit 1 (`Worker/SlotSupplierRegistry.pm:102-117, 141-148`), so supplier backpressure becomes an unconditional grant.
(Finding L19, probe `verify-45/memsafe-infra/resolve_permit.pl`.)

**Root cause.** `_resolve_permit` treats not-yet-resolved as resolved-with-default.

**Required behavior.** A pending reserve future defers the permit until it resolves; the permit carries the supplier's value; the slot is not handed out early.

**Acceptance criteria.**
- The committed probe adaptation asserts no permit is issued while the supplier future is pending and the eventual permit matches the resolved value.

**Test notes.** Check the shim-side expectation for reserve timing under the shim protocol if the fix changes callback ordering.

### R32: Implement Nexus cancel_task (Medium)

**Defect.** Nexus `cancel_task` is a silent no-op: `%running` is always empty (`Worker/NexusDispatcher.pm:109`), so the cancel lookup at `:93-98` never matches and `ack_cancel` (`:350-353`) is dead code.
(Finding L20.)

**Root cause.** Running operations are never registered in the map the cancel path reads.

**Required behavior.** Running nexus operations are tracked; a cancel_task cancels the matching operation's future, the handler observes cancellation, and the ack is sent.

**Acceptance criteria.**
- A replay or unit test dispatches a nexus task, delivers cancel_task, and asserts the operation future is cancelled and `ack_cancel` fires.

**Test notes.** `t/replay/nexus.t` has the harness; extend it rather than building a new one.

### R33: Reap Late Completions After Start and Connect Timeouts (Medium)

**Defect.** Start and connect timeouts abandon the bridge futures (`Test/DevServer.pm:174-187`; `Test/Client.pm:39-57`); a late success is dropped, leaking the dev-server CLI process or one connection per timeout.
(Finding L26, narrowed: at most one connection per occurrence, see Review Record sub-claim 4.)

**Root cause.** The timeout arm discards the pending future instead of attaching a reaper.

**Required behavior.** The timeout path attaches a continuation that reaps a late success: shut down the late-started CLI, close the late-established connection.

**Acceptance criteria.**
- A unit test forces the timeout with a stalled-then-resolving future and asserts the reaper runs (CLI shutdown or connection close observed).

**Test notes.** Related Future-state semantics are documented by `verify-45/memsafe-infra/future_semantics.pl`; R47 and R48 fix the sibling diagnostics in the same helpers.

### R34: Remove the Ephemeral-Port Race from DevServer Startup (Medium)

**Defect.** `Test/DevServer.pm:109, :143` picks a port with Net::EmptyPort inside the kernel's outbound ephemeral range and releases it before the server binds; under `prove -j4` this produced bind-failure and wrong-server flakes (the known updates.t flake).
(Finding T-flake, probe `verify-45/memsafe-infra/emptyport_range.pl`.)

**Root cause.** Time-of-check to time-of-use on a freed port, in a range the kernel also allocates from.

**Required behavior.** Startup is race-free under parallel prove: pass port 0 through core and read the bound port back, hand off a bound fd, or retry on bind failure with a fresh port.
The step-45 note lists these three options; any one suffices.

**Acceptance criteria.**
- An integration-style test (skip_all offline) starts four dev servers concurrently repeatedly without a bind failure or cross-connect.
- The updates.t flake no longer reproduces under `prove -lj4 t`.

**Test notes.** If the fix removes Net::EmptyPort entirely, R61 (the dependency phase bug) closes with it; coordinate.

### R35: Validate Activity Options at the Call Site (Medium)

**Defect.** `execute_activity`/`execute_local_activity` (`Workflow/Runner.pm:449-511, :562` onward) neither require a timeout nor reject unknown options; a call with no timeout hangs in infinite retry, and typos vanish silently.
(Finding A2.)

**Root cause.** Options are pattern-matched permissively with no schema.

**Required behavior.** Missing both `start_to_close_timeout` and `schedule_to_close_timeout` raises a typed argument error (Python parity); unknown option keys raise the same class.

**Acceptance criteria.**
- Replay tests assert the typed error for the no-timeout call and for an unknown key, for both activity kinds.

**Test notes.** Coordinate with R44 (client-side unknown-option strictness) so the SDK has one strictness story.

### R36: Complete the Workflow info() Surface (Medium)

**Defect.** `Workflow::info()` returns a bare hashref missing `workflow_id`, `attempt`, and `task_queue` (`Workflow/Runner.pm:391-407`), and the POD (`Workflow.pm:470-471`) links a class that does not exist.
(Finding A5.)

**Root cause.** info() shipped minimal and the POD described the plan.

**Required behavior.** info() exposes the documented fields including `workflow_id`, `attempt`, and `task_queue`, populated from the activation/init data; the POD names what actually ships.

**Acceptance criteria.**
- A replay test asserts the three fields carry the values from the initializing activation.
- xt pod tests pass with the corrected POD.

**Test notes.** Field list should be checked against Python's `workflow.info()` for naming parity.

### R37: Wire or Reject start_workflow Extended Options (Medium)

**Defect.** `Client.pm:572-574` silently deletes `static_summary`, `static_details`, and `versioning_override` from start_workflow options.
(Finding A7.)

**Root cause.** Placeholder deletion outlived the feature work.

**Required behavior.** The three options are wired to their proto fields; if any cannot be supported, passing it raises a typed error instead of silence.

**Acceptance criteria.**
- An integration or request-capture test asserts the fields appear in the StartWorkflowExecution request when provided.

**Test notes.** `static_summary`/`static_details` map through the user-metadata payloads; check Python's encoding.

### R38: Make the Process-Global Overrides Accountable (Medium)

**Defect.** Any Worker construction permanently installs process-global `CORE::GLOBAL` overrides (`Worker.pm:106-111, 139-140`) with no uninstall, affecting all code in the process for its lifetime.
(Finding A15.)

**Root cause.** Installation is one-way and undocumented.

**Required behavior.** Outside workflow context the overrides are transparent passthroughs (verified, not assumed), the residency is documented in the Worker POD, and either an uninstall exists for the last-worker-destroyed case or the POD states the permanence explicitly.

**Acceptance criteria.**
- A test asserts `time`/`rand` behave stock outside workflow context while a worker exists.
- POD documents the override lifecycle; xt stays green.

**Test notes.** Design with R27; the Definition-load installation point changes the lifecycle story.

### Low-Medium

### R39: Add the Missing on_cancel Hook to Child-Workflow Signals (Low-Medium)

**Defect.** `_signal_child_workflow` (`Workflow/Runner.pm:908-936`) lacks the on_cancel hook its external-signal sibling has (`:996-1010`), so a signal cancelled in flight never emits CancelSignalWorkflow.
(Finding R10.)

**Root cause.** The two arms were written separately and one lost the hook.

**Required behavior.** Parity with the external arm: cancelling a pending child-signal future emits the cancel command.

**Acceptance criteria.**
- A replay test cancels a pending child signal and asserts the cancel command is emitted.

**Test notes.** Small; batch with the R8 through R10 cluster tests since the harness overlaps.

### R40: Cover the Post-Cancel Paths in the Replay Suite (Low-Medium)

**Defect.** The R4-family post-cancel paths ship untested; only the nexus pre-cancel case is covered (`t/replay/nexus.t:390`).
(Finding T8.)

**Root cause.** The cancellation test matrix stops at pre-cancel.

**Required behavior.** Replay coverage exists for post-cancel behavior across the activity, child-workflow, timer, and local-activity arms, in both catch-and-cleanup and propagate shapes.

**Acceptance criteria.**
- `t/replay/` contains post-cancel cases for the four arms; the R8 through R10 reproduce-first tests count toward this and the remaining arms are filled in.

**Test notes.** This requirement is the coverage ledger for the R8 cluster; close it last in that cluster.

### R41: Point the Tracing Tests at the Wired Behavior (Low-Medium)

**Defect.** `t/unit/tracing.t:33-187` asserts private helpers and never exercises the wrapper wiring, which is how the R22 stub stayed green.
(Finding T3.)

**Root cause.** Tests were written against internals instead of the interceptor contract.

**Required behavior.** The tracing tests drive the public interceptor surface (intercept a call, observe the span and headers) and would fail against a delegation-only stub.

**Acceptance criteria.**
- Reverting the R22 implementation makes these tests fail (mutation check noted in the test comments).

**Test notes.** Part of the R22 cluster.

### R42: Fix the OpenTelemetry-Installed Test Failure (Low-Medium)

**Defect.** With the OpenTelemetry module installed, the gated subtest at `t/unit/tracing.t:201` fails: it asserts `->tracer` on a tracer-less interceptor.
(Finding T4, probe under `verify-45/api-otel/`.)

**Root cause.** The gate tests for module presence but the fixture never provides a tracer.

**Required behavior.** The suite passes with and without OpenTelemetry installed.

**Acceptance criteria.**
- CI-style run with OpenTelemetry present passes; the gated subtest constructs its fixture correctly.

**Test notes.** Folds into the R22/R41 rewrite of this file.

### R43: Make WorkflowReplay's Nondeterminism Claim True or Scoped (Low-Medium)

**Defect.** `Test/WorkflowReplay.pm:59-95` never engages core's history comparison, while `README.md:545-552` promises nondeterminism detection through replay.
(Finding R14.)

**Root cause.** The harness replays through the Perl runner only; the README describes the core replayer.

**Required behavior.** Either the harness engages the core replayer for history comparison, or the README and POD scope the claim to what the Perl-side replay actually checks.

**Acceptance criteria.**
- If implemented: a replay test with a mutated history asserts a nondeterminism error.
- If scoped: README and POD match the shipped check; a grep probe finds no overclaim.

**Test notes.** Decide direction with the temporal-docs MCP input on what core's replayer exposes through the C bridge.

### R44: Unify Unknown-Option Strictness on the Client Surface (Low-Medium)

**Defect.** Strictness is inconsistent: `Client.pm:285-299` rejects unknowns while `Client/WorkflowHandle.pm:56` ignores them, so `result(follow_run => 0)` (a typo for the real option) silently follows continue-as-new.
(Finding A10.)

**Root cause.** Per-method option handling with no shared validator.

**Required behavior.** One strictness rule across the client surface: unknown options raise the typed argument error everywhere.

**Acceptance criteria.**
- A test sweep over the public client methods asserts the typo case raises.

**Test notes.** Coordinate with R35 for the same rule inside workflow context.

### R45: Revive the Dead Nexus Integration Test (Low-Medium)

**Defect.** `t/integration/nexus.t` cannot run: it calls a nonexistent `with_worker`, passes kwargs where connect takes positionals, and treats an iterator as an arrayref (`nexus.t:74-77, :90, :103-108`); the env gate has hidden this since it landed.
(Finding T7.)

**Root cause.** The file was written against an imagined API and never executed.

**Required behavior.** The file compiles, runs green against a dev server, and `skip_all`s offline like its siblings.

**Acceptance criteria.**
- `prove -l t/integration/nexus.t` passes with a dev server available; `perl -c` passes regardless.

**Test notes.** R70's guard-conversion sweep should confirm no other integration file is compile-dead.

### R46: Set the DevServer Shutdown Flag Only on Success (Low-Medium)

**Defect.** `Test/DevServer.pm:207-208` sets `$is_shutdown = 1` before doing the work, so a throwing shutdown can never be retried.
(Finding L25.)

**Root cause.** Flag-first ordering.

**Required behavior.** The flag is set after successful shutdown; a failed shutdown leaves the object retryable.

**Acceptance criteria.**
- A unit test makes the first shutdown throw and asserts a second call still attempts the work.

**Test notes.** Same test file as R3 and R33.

### R47: Make Timeout Diagnostics Reachable in the Await Helpers (Low-Medium)

**Defect.** The timeout diagnostics in all three await helpers are unreachable (`Test/DevServer.pm:35-37`; `Test/Worker.pm:45-46`); callers see the raw "was cancelled" Future message instead.
(Finding T5, probe `verify-45/memsafe-infra/future_semantics.pl`.)

**Root cause.** After `wait_any`, the loser future's state does not match the branch the helpers test for.

**Required behavior.** A timed-out await surfaces the intended diagnostic (what was awaited, for how long).

**Acceptance criteria.**
- A unit test times out each helper and asserts the diagnostic text, not "was cancelled".

**Test notes.** The probe documents the actual Future 0.52 states; encode them in the test comments.

### R48: Make the Wedged-Connect Retry Branch Reachable (Low-Medium)

**Defect.** `connect_with_retry`'s wedged-connect retry branch (`Test/Client.pm:43-51`) is unreachable for the same Future-state reason as R47.
(Finding T6, probe.)

**Root cause.** Same state-mismatch as R47.

**Required behavior.** A wedged connect is detected and retried as the helper intends.

**Acceptance criteria.**
- A unit test stalls the first connect and asserts a retry occurs.

**Test notes.** One diff with R47.

### R49: Register Dev-Server Teardown in END Blocks (Low-Medium)

**Defect.** Only 3 of 33 integration files use END-block teardown (contrast `t/integration/updates.t:176-179` with the hazard the SDK itself documents at `Test/DevServer.pm:244-251`); a file-level die orphans the CLI process.
(Finding T9.)

**Root cause.** The early integration template used inline teardown and the suite copied it.

**Required behavior.** Every integration file that provisions a dev server registers teardown in an END block.

**Acceptance criteria.**
- A new xt author test statically asserts the END-teardown pattern in every DevServer-using integration file.

**Test notes.** Mirrors samples-perl R17; the xt probe keeps future files honest.

### Low

### R50: Add Direct ChildCancellation Tests (Low)

**Defect.** Zero direct tests exist for `Activity/ChildCancellation.pm`; a wait_any-loser test fails today.
(Finding T2.)

**Root cause.** The class shipped inside the pool work without its own coverage.

**Required behavior.** Direct unit coverage for the class, including the R23 race shape.

**Acceptance criteria.**
- A unit file covers construction, cancellation observation, and the wait_any race; the race case is the R23 RED test.

**Test notes.** Part of the R23 cluster.

### R51: Correct the Pre-Scheduled-Cancel Comment in Runner (Low)

**Defect.** The comment at `Workflow/Runner.pm:1188-1193` claims a pre-scheduled-cancel mirror for activities and children that does not exist, and the nexus arm contradicts its own header comment.
(Finding R3, equal to L31b.)

**Root cause.** The comment describes a design that was never built; the real mechanism is the `_apply_cancel_workflow` fallback.

**Required behavior.** The comments describe the actual mechanism, post-R8 through R10, since that cluster changes what the fallback does.

**Acceptance criteria.**
- The comments match the shipped control flow; reviewer sign-off in the fix commit message.

**Test notes.** Land after R8 through R10 so the comment is written once against the fixed behavior; supersedes samples-perl forward 3.

### R52: Do Not Park Wait-Type Local Activities Forever on Evict (Low)

**Defect.** Evict's wait-honoring cancel parks wait-type local activities forever (`Workflow/Runner.pm:1537, :711-716, :3347-3358`); eviction should be unconditional.
(Finding L8, analysis.)

**Root cause.** Evict reuses the caller-facing cancel path, which honors the wait type.

**Required behavior.** Eviction cancels immediately regardless of the LA's cancellation type; the run is always releasable.

**Acceptance criteria.**
- A replay test evicts a run holding a wait-type LA and asserts eviction completes.

**Test notes.** Batch with R12 and R53 into the cancellation-type test file.

### R53: Guard Wait-Type LA Cancel to At-Most-Once (Low)

**Defect.** Wait-type LA cancel lacks an at-most-once guard (`Workflow/Runner.pm:711-716, :738-748`); a second cancel emits a duplicate RequestCancelLocalActivity.
(Finding L10, analysis.)

**Root cause.** No sent-flag on the cancel path.

**Required behavior.** At most one RequestCancelLocalActivity per LA sequence number.

**Acceptance criteria.**
- A replay test double-cancels and asserts exactly one cancel command.

**Test notes.** Same file as R52.

### R54: Ship the Promised Workflow memo and search_attributes Readers (Low)

**Defect.** The v1 spec promises `Workflow::memo` and `Workflow::search_attributes` readers (archived spec lines 1869-1870); neither shipped.
(Finding A6.)

**Root cause.** The readers fell out of the v0.1 scope cut and were never restored.

**Required behavior.** Both readers exist with the spec's contract, returning the current values including upserted changes, Python-parity shapes.

**Acceptance criteria.**
- Replay tests read both before and after an upsert and assert the updated values.

**Test notes.** The upsert path exists; the readers are the missing half.

### R55: Raise Typed Errors for Missing Workflow-Context Arguments (Low)

**Defect.** Missing-argument errors in workflow context are plain string dies (`Workflow/Runner.pm:451-453, :579-581`).
(Finding A14.)

**Root cause.** Validation predates the exception hierarchy.

**Required behavior.** The dies become `Temporalio::Exception::Argument` (or the documented class), catchable and testable by class.

**Acceptance criteria.**
- Tests assert the class, not the message, at both sites.

**Test notes.** One diff with R35 if convenient; same validation region.

### R56: Wrap Failure-Conversion Errors in the DataConverter Error (Low)

**Defect.** Failure conversion at `Converter/Data.pm:152-153, :182` runs outside the DataConverter error wrapping that payload conversion gets.
(Finding L22.)

**Root cause.** The wrapping was added for payloads only.

**Required behavior.** Failure conversion errors surface as the same typed DataConverter exception as payload errors.

**Acceptance criteria.**
- A unit test with a poisoned failure converter asserts the typed wrapper.

**Test notes.** Small; batch with R57 through R59.

### R57: Check utf8::decode and Fail Loudly on Malformed Input (Low)

**Defect.** `Converter/Payload/JsonProtobuf.pm:48` calls `utf8::decode` unchecked; malformed UTF-8 passes through as latin-1 mojibake instead of raising.
(Finding L23, probe `verify-45/pool-payload/probe_cause_mojibake.pl`.)

**Root cause.** The boolean return of `utf8::decode` is ignored.

**Required behavior.** A failed decode raises the typed conversion error; no silent mojibake.

**Acceptance criteria.**
- The committed probe adaptation feeds malformed UTF-8 and asserts the typed error.

**Test notes.** Same probe file covers R68; adapt once, split assertions.

### R58: Define from_payload Behavior for Empty Payload Data (Low)

**Defect.** `from_payload` on a json/plain payload with empty data dies "malformed JSON string".
(Finding ADJ1, verifier discovery while re-running the UTF-8 probe.)

**Root cause.** The empty-data edge reaches the JSON parser raw.

**Required behavior.** Empty payload data has defined behavior: either a documented mapping (undef) or the typed conversion error, matching what Python's converter does with the same payload; never a raw die.

**Acceptance criteria.**
- A unit test covers the empty-data payload for the json and plain encodings and asserts the documented outcome.

**Test notes.** Check `../sdk-python` converter behavior first; parity decides the direction.

### R59: Reconcile BinaryPlain and Json POD with Their Claiming Code (Low)

**Defect.** `Converter/Payload/BinaryPlain.pm:25-27` POD contradicts the claiming logic at `:53-56` (and the Json sibling shares the drift).
(Finding L24.)

**Root cause.** POD written before the claim rules settled.

**Required behavior.** POD states the actual claim conditions.

**Acceptance criteria.**
- xt pod tests pass; a reviewer can map each POD claim to a line of claiming code.

**Test notes.** Doc-only.

### R60: Align Metric-Drop Behavior with Its Documentation (Low)

**Defect.** `Runtime/MetricMeter.pm:46-52` drops unbound metric records while the doc says records are never dropped, and the promised rate-limited warning (around `:217-218`, `:130`) warns unconditionally.
(Finding L28.)

**Root cause.** Doc and implementation evolved separately.

**Required behavior.** Either buffer-until-bound so the "never dropped" claim is true, or the doc states the drop window; the warning is rate-limited as promised either way.

**Acceptance criteria.**
- A unit test covers the unbound-record path against the documented behavior and asserts warn rate-limiting.

**Test notes.** Small behavior choice; note the decision in the commit message.

### R61: Declare Net::EmptyPort in the Right Dependency Phase (Low)

**Defect.** `Test/DevServer.pm:12` loads Net::EmptyPort at runtime, but `sdk/cpanfile` declares it test-phase only, so a non-test consumer of Test::DevServer breaks.
(Finding L29.)

**Root cause.** Phase misclassification; Test::* modules ship in the runtime dist.

**Required behavior.** The dependency phase matches the usage, unless R34 removes the module entirely.

**Acceptance criteria.**
- cpanfile phase matches every `use` site, verified by a dependency-audit pass.

**Test notes.** Close with R34.

### R62: Stop Masking Pool and Worker Error Causes (Low)

**Defect.** A pool child's `require` failure is swallowed (`Activity/Pool.pm:98-101`), and `Worker::run`'s finalize die masks the saved error (`Worker.pm:576-577, :855-864`).
(Finding L32.)

**Root cause.** Error propagation loses the original cause at two hand-off points.

**Required behavior.** The original error survives: require failures surface with the module name; finalize failures attach to, not replace, the saved error.

**Acceptance criteria.**
- Tests assert the original message is present in both shapes.

**Test notes.** Batch with the R4/R5 pool work.

### R63: Accept the Spec-Promised Workflow Argument Forms in start_workflow (Low)

**Defect.** `Client.pm:617-625` rejects the non-string workflow argument the v1 spec promises (definition class or ref).
(Finding A8.)

**Root cause.** Only the string form was implemented.

**Required behavior.** The spec-promised forms are accepted and resolve to the workflow type name.

**Acceptance criteria.**
- Unit tests pass a definition class and assert the resolved type in the request.

**Test notes.** Check the archived spec's exact promise before implementing.

### R64: Fix the list_workflows POD (Low)

**Defect.** `Client.pm:275-281, :1109-1111` POD is wrong twice: an async claim that does not hold, and it names a private iterator class yielding raw protos as the return contract.
(Finding A9.)

**Root cause.** POD written against an earlier design.

**Required behavior.** POD states the shipped sync/async behavior and the public return contract.

**Acceptance criteria.**
- xt pod tests pass; the described return type matches a test that exercises it.

**Test notes.** Batch with R65 and R66 as one POD pass.

### R65: Remove Stale "Arrives Later" POD for Shipped Features (Low)

**Defect.** `Client.pm:1010-1011`, `Worker.pm` around `:1060-1063`, and `Activity.pm:74-79` still say features arrive later that shipped in v0.2.
(Finding A11.)

**Root cause.** POD not swept at v0.2 close.

**Required behavior.** No "arrives later" text for shipped surface.

**Acceptance criteria.**
- A grep probe over lib for the stale phrases returns nothing.

**Test notes.** Part of the POD pass.

### R66: Document the Undocumented Worker and Connect Options (Low)

**Defect.** 10 of 33 `Worker->new` kwargs are undocumented, and the connect POD omits `interceptors`, `http_connect_proxy`, and `lazy`.
The step-45 sub-claim about `rpc_metadata` was refuted; it is documented (see Review Record).
(Finding A12; survey artifact `verify-45/api-otel/worker-pod.txt`.)

**Root cause.** Options landed feature-by-feature without POD entries.

**Required behavior.** Every accepted kwarg is documented with type and default.

**Acceptance criteria.**
- An xt author test cross-checks accepted kwargs against POD-documented ones for `Worker->new` and `connect`.

**Test notes.** The xt cross-check is the durable fix; it catches the next undocumented option too.

### R67: Map and Validate query reject_condition (Low)

**Defect.** `Client/WorkflowHandle.pm:379-381` passes `reject_condition` verbatim into the proto enum with no mapping, validation, or docs.
(Finding A13.)

**Root cause.** Enum plumbing was stubbed through.

**Required behavior.** Named values map to the proto enum; invalid values raise the typed argument error; POD lists the names (Python-parity naming).

**Acceptance criteria.**
- Unit tests cover each named value and one invalid value.

**Test notes.** Small; part of the client polish batch.

### R68: Accept Non-Temporalio Causes in Exception Chaining (Low)

**Defect.** `Exception.pm:20-27` rejects a non-Temporalio cause, so wrapping an arbitrary die loses the chain.
(Finding A16, probe `verify-45/pool-payload/probe_cause_mojibake.pl`.)

**Root cause.** An isa-check that is too narrow.

**Required behavior.** Any defined value is accepted as a cause; non-exception causes are stringified into a wrapper or stored as-is per the documented contract.

**Acceptance criteria.**
- The committed probe adaptation chains a plain string die and a foreign object and asserts both survive.

**Test notes.** Same probe file as R57.

### R69: Close the Four Verified Cross-SDK Divergences (Low)

**Defect.** Four divergences verified against reference SDKs: the schedule `backfills` kwarg missing; no activity `priority`/`summary` options; page-size defaults never sent on list calls; `execute_update` overrides the caller's `wait_for_stage`.
(Finding A17.)

**Root cause.** Parity gaps from the v0.2 sprint.

**Required behavior.** Each divergence closes to Python behavior, or is documented as a deliberate deviation with the reason (spec §0 allows surface-level deviation only).

**Acceptance criteria.**
- One test per item asserting the parity behavior (request capture for the wire-visible ones).

**Test notes.** Four small independent diffs; do not bundle them into one commit.

### R70: Convert Offline-Skipping Repro Guards to Replay Tests (Low)

**Defect.** All 10 integration repro guards skip offline, so the regressions they guard are unprotected in the default suite; only 4 replay guards exist.
(Finding T10.)

**Root cause.** Guards were written where the bug was observed, not where it is cheapest to detect.

**Required behavior.** Each repro guard that can be expressed as a replay test gets one; guards that genuinely need a server keep the integration form and gain a comment saying why.

**Acceptance criteria.**
- The offline suite fails if any converted guard's regression is reintroduced (mutation-check one of them during review).
- Remaining server-only guards carry the justification comment.

**Test notes.** Do this sweep last; earlier requirements add replay harness capability (R8 through R10) that makes more conversions possible.

## Feature Parity (R71 onward)

R71 through R97 come from a reference-SDK parity audit on 2026-07-06: a six-way fan-out over the client, worker, in-workflow, activity and conversion, nexus and interceptor, and schedule and runtime surfaces of `../sdk-python`, verified against source per spec §0.
Each requirement names its audit slice and finding, the Python source that is ground truth, and the Perl source it was checked against.
"Confidence" is the auditor's read of whether the gap is a real capability drop versus a deliberate Perl-idiom deviation; where a low-confidence item resolved to a documented deviation under spec §0 rather than an implementation, the requirement states that decision (R97 is the one such case).
The parity-versus-idiom judgment calls are resolved inline: R95 implements the from-history replayer, R96 exposes an activity context-detail accessor rather than mandating a logging framework, and R97 documents a deliberate deviation instead of porting deprecated APIs.
Every other item is an implementation requirement.

### Parity: High

### R71: Wire and Invoke the Workflow-Outbound Interceptor Chain (High)

**Defect.** `Temporalio::Worker::WorkflowOutbound` is defined (`Worker/Interceptor.pm:57-67`) but never used: no root outbound is built, the Runner never calls `WorkflowInbound.init(outbound)`, and no outbound method is invoked (`Workflow/Runner.pm:1690` builds only the inbound chain).
Every `execute_activity`, `start_child_workflow`, `signal_*`, and `continue_as_new` bypasses interceptors, and the base lacks `info()` and `start_nexus_operation()`.
This also caps R22: the OTel interceptor's outbound span table (`Contrib/OpenTelemetry/TracingInterceptor.pm:138-150`) is unreachable, so outbound trace-context injection cannot work even after R22 lands.
(Parity audit, nexus/interceptor finding 1; Python `worker/_interceptor.py:416-481`, Perl `Worker/Interceptor.pm`. Confidence: high.)

**Root cause.** The B7 live-hardening pass wired only the inbound chain; the outbound direction was never built.

**Required behavior.** The Runner constructs a root workflow-outbound interceptor, folds the configured interceptor list over it, calls `inbound->init(outbound)`, and routes `execute_activity`, `execute_local_activity`, `start_child_workflow`, `signal_child_workflow`, `signal_external_workflow`, `continue_as_new`, `start_nexus_operation`, and `info` through the outbound chain, matching Python.

**Acceptance criteria.**
- A replay test registers a workflow interceptor whose outbound `execute_activity` and `start_child_workflow` mutate a header or args, and asserts the mutation reaches the emitted command; the test fails against the current unwired base.

**Test notes.** Land before or with R22 so the OTel outbound spans have a chain to hang on.

### R72: Add the Activity-Outbound Interceptor and Wire ActivityInbound.init (High)

**Defect.** No `Temporalio::Worker::ActivityOutbound` class exists; `Worker/ActivityDispatcher.pm:152` builds the inbound chain but never calls `$inbound->init($outbound)`, so `activity.info()` and `activity.heartbeat()` go straight to `Activity/Context.pm` and a custom interceptor cannot observe or wrap them.
(Parity audit, nexus/interceptor finding 2; Python `worker/_interceptor.py:135-156`, Perl `Worker/ActivityDispatcher.pm`. Confidence: high.)

**Root cause.** The activity-outbound direction was never defined or wired.

**Required behavior.** Define `Temporalio::Worker::ActivityOutbound` with `info` and `heartbeat`, have the dispatcher build a root outbound and call `inbound->init(outbound)`, and route the Activity Context heartbeat and info through the outbound chain.

**Acceptance criteria.**
- A unit test with an activity interceptor overriding outbound `heartbeat` asserts the override fires when the activity body calls `heartbeat`.

### R73: Add the Nexus Operation Inbound Interceptor Role (High)

**Defect.** `Temporalio::Worker::Interceptor` (`Worker/Interceptor.pm:73-76`) defines only `intercept_activity` and `intercept_workflow`; there is no `intercept_nexus_operation` and no `NexusOperationInbound` base, and `NexusDispatcher::_handle_start` (`Worker/NexusDispatcher.pm:196`) and `_handle_cancel_operation` (`:257`) invoke the handler directly with no chain, so nexus start and cancel cannot be intercepted (no OTel nexus spans, no handler-side header extraction).
(Parity audit, nexus/interceptor finding 3; Python `worker/_interceptor.py:66-78, 500-528`, Perl `Worker/NexusDispatcher.pm`. Confidence: high.)

**Root cause.** The nexus interceptor role was never added to the interceptor surface.

**Required behavior.** Add `intercept_nexus_operation` and a `NexusOperationInbound` base with `execute_nexus_operation_start` and `execute_nexus_operation_cancel`, and have `NexusDispatcher` fold the interceptor list over a root that runs the handler.

**Acceptance criteria.**
- A unit test dispatches a nexus start task with an interceptor overriding `execute_nexus_operation_start` and asserts the override runs before the handler body.

### R74: Carry ApplicationError next_retry_delay Through Exception and Failure Proto (High)

**Defect.** `Exception/Application.pm:11-14` has no `next_retry_delay` field, and `Converter/Failure.pm:231-240, :251-261` never reads or writes `ApplicationFailureInfo.next_retry_delay`; the proto field exists (`share/proto/temporal/api/failure/v1/message.proto:27`), so this is a dropped capability.
(Parity audit, activity/conversion finding 1; Python `exceptions.py:133,168-175` and `converter/_failure_converter.py:160-162,340`, Perl `Exception/Application.pm`, `Converter/Failure.pm`. Confidence: high. Distinct from R5, which carries type/non_retryable/details/cause over the fork channel only.)

**Root cause.** The option and its proto mapping were never added.

**Required behavior.** `Exception::Application` accepts `next_retry_delay`, and the failure converter round-trips it to and from `ApplicationFailureInfo.next_retry_delay`, matching Python; a set value overrides the next retry interval.

**Acceptance criteria.**
- A unit test builds an ApplicationError with `next_retry_delay`, runs `to_failure` then `from_failure`, and asserts the value survives and appears in the proto field.

### R75: Support encode_common_attributes on the Failure Converter (High)

**Defect.** `Converter/Failure.pm` always writes cleartext `message` and `stack_trace` and never produces or reads `encoded_attributes`; `Converter/Data.pm:99-102` will codec-transform `encoded_attributes` if present, but nothing produces it, so a configured encryption codec cannot protect the failure message or stack trace, and no `DefaultFailureConverterWithEncodedAttributes` equivalent is constructible.
(Parity audit, activity/conversion finding 2; Python `converter/_failure_converter.py:84,119-127,312-327,461-468`, Perl `Converter/Failure.pm`. Confidence: high. R7 extends the codec surface but assumes the payloads already exist; R56 only wraps failure-conversion errors.)

**Root cause.** The failure converter shipped without the encode-common-attributes relocation Python performs.

**Required behavior.** The failure converter accepts `encode_common_attributes`; when set, `to_failure` relocates message and stack_trace into an `encoded_attributes` payload (message becomes "Encoded failure", stack_trace ""), and `from_failure` restores them, so the codec chain can encrypt them.

**Acceptance criteria.**
- A test with `encode_common_attributes` on and a marker codec asserts the on-wire Failure has message "Encoded failure" and a codec-tagged `encoded_attributes`, and that `from_failure` recovers the original message and stack trace.

### R76: Expose Activity Cancellation Details and Reason (High)

**Defect.** `Worker/ActivityDispatcher.pm:105-113` receives the `Cancel` job (which carries `reason` and an `ActivityCancellationDetails`, proto `activity_task.proto`) but fires only `->cancel` on the token and discards both; `Activity/Context.pm` exposes a single cancellation future whose POD conflates server-cancel with worker-shutdown, so a body cannot tell why it was cancelled (paused, reset, timed out, worker shutdown, not found, explicit cancel).
(Parity audit, worker finding 2 and activity/conversion finding 3; Python `activity.py:169-191,315-317` and `worker/_activity.py:221-226`, Perl `Worker/ActivityDispatcher.pm`, `Activity/Context.pm`. Confidence: high. Distinct from R18/R19, which cover sync-activity heartbeat relay and cancel delivery, not the reason.)

**Root cause.** The dispatcher drops the cancel reason and details.

**Required behavior.** The dispatcher captures `reason` and `ActivityCancellationDetails` and exposes them on the activity context (a `cancellation_details` accessor with the boolean fields), matching Python, so a body can distinguish the cancellation cause.

**Acceptance criteria.**
- A test delivers a cancel carrying `WORKER_SHUTDOWN` (and separately `PAUSED`) and asserts the context reports the matching reason and details.

### R77: Add workflow.uuid4 Deterministic UUID (High)

**Defect.** `Workflow.pm` exposes `random` (`:72`) but no `uuid4`; the only UUID code is client-side `Temporalio::Client::_new_uuid`, which is non-deterministic and not workflow-safe.
(Parity audit, in-workflow finding 1; Python `workflow/_context.py:866`, Perl `Workflow.pm`. Confidence: high.)

**Root cause.** The deterministic UUID helper was never added to the workflow surface.

**Required behavior.** Add `Temporalio::Workflow::uuid4` returning a v4 UUID derived from the workflow's deterministic RNG, stable across replays of the same run.

**Acceptance criteria.**
- A replay test asserts `uuid4()` is stable across replay, differs from a second call, and is seeded from the activation randomness seed.

### R78: Carry a Summary on Timers, sleep, and wait_condition Timeouts (High)

**Defect.** `Workflow::sleep`/`start_timer` take only `$seconds` (`Workflow.pm:241,250`), `Runner::start_timer` (`Runner.pm:1220`) emits StartTimer with no user-metadata, and `wait_condition` (`Runner.pm:1366,1388`) passes no summary; local activities already carry `summary`, so timers are the only omission.
(Parity audit, in-workflow finding 2; Python `workflow/_context.py:878,894`, Perl `Workflow.pm`, `Workflow/Runner.pm`. Confidence: high. R69 covers activity summary only.)

**Root cause.** The timer command builder was never extended for user-metadata.

**Required behavior.** `sleep`/`start_timer` accept a `summary` and `wait_condition` a `timeout_summary`, converted to the StartTimer user-metadata single-line summary, matching Python.

**Acceptance criteria.**
- A replay test asserts the StartTimer command carries the user-metadata summary payload when passed, and none when omitted.

### R79: Expose Per-Activation Workflow Info Accessors (High)

**Defect.** No accessors exist for the current activation's `history_length`, `history_size_bytes`, `build_id`, or `continue_as_new_suggested` (grep of `sdk/lib` finds none); R36 completes only the static `info()` fields, while these four are per-activation dynamic values the runner receives but never surfaces.
(Parity audit, in-workflow finding 3; Python `workflow/_context.py:140,165,175,185`, Perl `Workflow/Runner.pm`. Confidence: high.)

**Root cause.** The dynamic per-activation fields were never plumbed to the context.

**Required behavior.** Surface `get_current_history_length`, `get_current_history_size`, `get_current_build_id`, and `is_continue_as_new_suggested` (or the equivalent info accessors), updated each activation, so authors can gate continue-as-new on history growth.

**Acceptance criteria.**
- A replay test drives an activation carrying these fields and asserts each accessor returns the delivered value.

### R80: Add the max_concurrent_nexus_tasks Worker Kwarg (High)

**Defect.** The fallback fixed tuner hardcodes `nexus_task_slots => 100` (`Worker.pm:300,416`); no `max_concurrent_nexus_tasks` field exists (`Worker.pm:60-62`) and it is absent from the tuner mutual-exclusion set (`Worker.pm:959-961`), so the nexus pool is only tunable by building a full custom tuner.
(Parity audit, worker finding 1; Python `worker/_worker.py:31,129-133`, Perl `Worker.pm`, `Worker/Tuner.pm`. Confidence: high.)

**Root cause.** The kwarg was left as a fixed v0.1 default and never surfaced.

**Required behavior.** `Worker->new` accepts `max_concurrent_nexus_tasks`, mutually exclusive with `tuner`, feeding the synthesized fixed tuner's nexus slot supplier; unset keeps the 100 default.

**Acceptance criteria.**
- A worker built with `max_concurrent_nexus_tasks => N` packs a FixedSize nexus supplier of N into the tuner, and passing it alongside `tuner` throws the mutual-exclusion error.

### R81: Add fairness_key and fairness_weight to Priority (High)

**Defect.** `Common/Priority.pm` declares and encodes only `priority_key`; the vendored proto (`share/proto/temporal/api/common/v1/message.proto:344,354`) already carries `fairness_key` and `fairness_weight`, so this is a dropped field set, not a pin limitation.
(Parity audit, schedule/runtime finding 3; Python `common.py:1149-1220`, Perl `Common/Priority.pm`. Confidence: high.)

**Root cause.** Priority shipped with only the first field.

**Required behavior.** `Priority` accepts `fairness_key` (string) and `fairness_weight` (float) and encodes both into `temporal.api.common.v1.Priority`, matching Python.

**Acceptance criteria.**
- A unit test constructs a Priority with all three fields and asserts `to_proto` sets `priority_key`, `fairness_key`, and `fairness_weight`.

### R82: Encode static_summary and static_details on the Schedule Action (High)

**Defect.** `Schedule/Action.pm:28-39` declares no `static_summary`/`static_details`, and `_to_proto` (`:73-124`) never sets `user_metadata`; this is a separate code path from the direct `start_workflow` (R37) and the schedule backfills kwarg (R69).
(Parity audit, schedule/runtime finding 1; Python `client/_schedule.py:551-552`, Perl `Schedule/Action.pm`. Confidence: high.)

**Root cause.** The schedule action builder was not extended when user-metadata landed.

**Required behavior.** `Schedule::Action::StartWorkflow` accepts `static_summary` and `static_details` and encodes them into the `NewWorkflowExecutionInfo.user_metadata` payloads, matching Python.

**Acceptance criteria.**
- A request-capture or replay test creating a schedule with both asserts they appear as encoded payloads in the emitted `user_metadata`.

### Parity: Medium

### R83: Expose a User-Facing Metric Meter in Workflow, Activity, and Nexus Context (Medium)

**Defect.** No workflow, activity, or nexus context exposes a meter user code can emit to (grep of `sdk/lib` finds none); `Runtime/MetricMeter.pm` is only the custom-sink adapter that consumes core-emitted metrics, so user code cannot record a counter, histogram, or gauge to the configured exporter.
(Parity audit, in-workflow finding 6, schedule/runtime finding 2, and nexus finding 4; Python `activity.py:247,461`, `workflow/_context.py:710`, `nexus/_operation_context.py:107`, Perl `Activity/Context.pm`, `Runtime/MetricMeter.pm`. Confidence: medium-high. Distinct from R60, which covers custom-sink drop behavior.)

**Root cause.** Only the metric-consumption side was built; the emission side was never exposed to user code.

**Required behavior.** Workflow, activity, and nexus context expose a core-backed metric meter that creates counters, histograms, and gauges (with per-call attributes) delivered to the configured exporter; the workflow meter no-ops during replay, matching Python.

**Acceptance criteria.**
- A replay test records a counter via the workflow meter and asserts it emits when live and is suppressed during replay.
- A test records a counter from an activity and asserts it reaches a test buffer or exporter.

### R84: Provide Worker-Shutdown Detection Inside Activities (Medium)

**Defect.** `Activity/Context.pm:28-30` folds worker shutdown into the single cancellation token; there is no separate worker-shutdown event or query, so an activity cannot distinguish graceful worker shutdown from an ordinary cancel or await shutdown independently.
(Parity audit, activity/conversion finding 4; Python `activity.py:400-438`, Perl `Activity/Context.pm`. Confidence: medium.)

**Root cause.** Worker shutdown was never signalled to activity bodies as a distinct event.

**Required behavior.** The activity context exposes `is_worker_shutdown` and an awaitable shutdown future, fired when the worker begins shutdown, distinct from cancellation, matching Python.

**Acceptance criteria.**
- A test triggers worker shutdown while an activity awaits and asserts the activity observes `is_worker_shutdown` true and its shutdown future resolves, without a plain cancel being indistinguishable.

### R85: Complete Activity Info with priority and retry_policy (Medium)

**Defect.** `Worker/ActivityDispatcher.pm:320-341` omits `priority` and `retry_policy` from the built Info, both present on the `ActivityTask.Start` proto.
(Parity audit, activity/conversion finding 5; Python `activity.py:130-136`, Perl `Worker/ActivityDispatcher.pm`. Confidence: medium. R36 completes the workflow info(), not the activity Info.)

**Root cause.** The Info builder shipped without the two fields.

**Required behavior.** Activity Info carries `priority` and `retry_policy` populated from the start job, matching Python naming.

**Acceptance criteria.**
- A dispatch test with a start job carrying a retry policy and priority asserts both surface on the activity Info.

### R86: Support Runtime Signal, Query, and Update Handler Registration (Medium)

**Defect.** Handlers bind only at definition time via `:Signal`/`:Query`/`:Update` attributes; there is no way to register or replace a named or dynamic handler at runtime from workflow code (no `set_*_handler`/`get_*_handler` in Runner or Workflow), though the dynamic catch-all attribute is supported.
(Parity audit, in-workflow finding 4; Python `workflow/_workflow_ops.py:833-985`, Perl `Workflow/Definition.pm`, `Workflow/Runner.pm`. Confidence: medium.)

**Root cause.** Handler installation is compile-time only.

**Required behavior.** Provide runtime setters and getters that install or replace named and dynamic signal, query, and update handlers on the running instance, with buffered-signal replay semantics matching Python.

**Acceptance criteria.**
- A replay test installs a signal handler via the setter after start, delivers a signal for that name, and asserts the new handler runs and a buffered pre-registration signal drains on registration.

### R87: Honor Per-Handler HandlerUnfinishedPolicy (Medium)

**Defect.** `Workflow/Attributes.pm` parses only `name` and `dynamic`; there is no `unfinished_policy`, and the warn-on-abandon behavior (`Workflow.pm:418-421`) is unconditional with no per-handler opt-out.
(Parity audit, in-workflow finding 5; Python `workflow/_handlers.py:36`, Perl `Workflow/Attributes.pm`. Confidence: medium.)

**Root cause.** The policy option was never added to the handler attributes.

**Required behavior.** `:Signal` and `:Update` accept an unfinished-handler policy; ABANDON suppresses the completion warning for that handler, matching Python's default-warn, opt-out-abandon.

**Acceptance criteria.**
- A replay test completes a workflow with an in-flight ABANDON-policy update handler and asserts no warning, while the default policy still warns.

### R88: Expose Last-Completion-Result and Last-Failure (Medium)

**Defect.** No accessors exist for the initializing activation's `last_completion_result` or `last_failure` (grep of `sdk/lib` finds none), so a cron or scheduled workflow cannot read the previous run's result or prior failure.
(Parity audit, in-workflow finding 7; Python `workflow/_context.py:675,688,696`, Perl `Workflow/Runner.pm`. Confidence: medium.)

**Root cause.** The carry-over fields on InitializeWorkflow are never surfaced.

**Required behavior.** Surface `has_last_completion_result`, `get_last_completion_result`, and `get_last_failure` from the initializing activation with the documented decode and type-hint behavior.

**Acceptance criteria.**
- A replay test seeds an InitializeWorkflow with a last-completion-result and a last-failure and asserts the accessors return the decoded value and the typed failure.

### R89: Restore Dropped Nexus Handler-Context Capabilities (Medium)

**Defect.** `Temporalio::Nexus` (`Nexus.pm:40-54`) omits `wait_for_worker_shutdown`/`_sync`, its `is_worker_shutdown` reads a `$IS_WORKER_SHUTDOWN` (`Nexus.pm:29,54`) no dispatcher ever sets (always false), and `OperationInfo` (`Nexus/OperationContext.pm:18-28`) omits `namespace`, which Python's Info carries. (The metric meter is covered by R83.)
(Parity audit, nexus finding 4; Python `nexus/_operation_context.py:82-147`, Perl `Nexus.pm`, `Nexus/OperationContext.pm`. Confidence: medium.)

**Root cause.** The nexus handler context shipped partial and the shutdown flag was never wired.

**Required behavior.** Add `namespace` to `OperationInfo`, add `wait_for_worker_shutdown` and its sync variant, and set the shutdown flag during dispatcher drain so `is_worker_shutdown` reflects reality.

**Acceptance criteria.**
- A unit test inside a dispatched nexus operation asserts `OperationInfo->namespace` matches the worker namespace and `is_worker_shutdown` flips true once the dispatcher enters shutdown drain.

### R90: Implement Lazy Client Connections (Medium)

**Defect.** `Client.pm:817,829-831` accepts `lazy` then throws "lazy client connections are not supported in v0.1"; R66 asks only to document `lazy`, which presumes it works, so R66 does not close this.
(Parity audit, client finding 3; Python `_client.py:151,205-207`, Perl `Client.pm`. Confidence: medium.)

**Root cause.** The option was stubbed as rejected and never implemented; the reject message is stale in a v0.2 tree.

**Required behavior.** `connect(lazy => 1)` returns a client that defers the gRPC connection until the first RPC; the eager path is unchanged when `lazy` is false or absent.

**Acceptance criteria.**
- A test constructs a lazy client against an unreachable target without error and asserts the connection is attempted only on the first RPC.

### R91: Expose Raw Service Clients on the Client (Medium)

**Defect.** No raw RPC passthrough exists (grep for `operator_service`/`workflow_service`/`service_client` in `sdk/lib` returns nothing); `Client/Connection.pm` holds only the core client pointer, so operator-namespace RPCs (add/remove search attributes, describe cluster) and any raw service call are unreachable.
(Parity audit, client finding 1; Python `_client.py:307-322`, Perl `Client.pm`, `Client/Connection.pm`. Confidence: medium.)

**Root cause.** Only the high-level API was built; the low-level escape hatch was never exposed.

**Required behavior.** The Client exposes a low-level service handle over the WorkflowService and OperatorService RPC surface (at minimum operator search-attribute management), matching Python's `operator_service`/`workflow_service` passthrough.

**Acceptance criteria.**
- A test issues an operator-service RPC (request-captured or skip_all offline) through the handle and asserts the request is formed and sent.

### R92: Add WorkflowHandle get_update_handle (Medium)

**Defect.** `Client/WorkflowHandle.pm` has no `get_update_handle`; the capability exists (`Client/WorkflowUpdateHandle.pm:41-79` polls purely from id/run/update-id with a public constructor), so only the ergonomic accessor is missing.
(Parity audit, client finding 2; Python `_workflow.py:978,1008`, Perl `Client/WorkflowHandle.pm`. Confidence: medium.)

**Root cause.** The accessor was never added even though its backing handle is public.

**Required behavior.** `WorkflowHandle` gains `get_update_handle(update_id, run_id => ..., result_type => ...)` returning a `WorkflowUpdateHandle` bound to the handle's run, Python parity.

**Acceptance criteria.**
- A test builds a handle via `get_update_handle` and asserts `result` polls `PollWorkflowExecutionUpdate` with the given update id and the handle's run id.

### R93: Honor a Client-Level Default Query Reject Condition (Medium)

**Defect.** `Client.pm` connect (`:800-824`) neither accepts nor stores `default_workflow_query_reject_condition`, and `Client/WorkflowHandle.pm:379-380` reads only a per-call `reject_condition`; R67 covers only per-call enum mapping, not a connect-level default.
(Parity audit, client finding 4; Python `_client.py:144-145,184-187`, Perl `Client.pm`. Confidence: medium.)

**Root cause.** The connect-level default was never added.

**Required behavior.** `connect` accepts `default_workflow_query_reject_condition`, applied by `query` when the call omits `reject_condition`; a per-call condition overrides it.

**Acceptance criteria.**
- A test connects with the default set, queries without a per-call condition, and asserts the outbound `QueryWorkflow` carries the client default; a per-call value overrides.

### R94: Add an on_fatal_error Worker Hook (Medium)

**Defect.** `Worker.pm` has no `on_fatal_error` field; `run()` re-raises loop failures (`Worker.pm:568,589`) with no user callback, so a caller can only catch the die after `run()` unwinds, not observe it before the shutdown sequence.
(Parity audit, worker finding 3; Python `worker/_worker.py:47,202-204`, Perl `Worker.pm`. Confidence: medium.)

**Root cause.** The hook was never added to the worker surface.

**Required behavior.** `Worker->new` accepts an `on_fatal_error` coderef invoked with the error before the fatal-path shutdown; exceptions from it are logged and ignored, matching Python.

**Acceptance criteria.**
- A worker whose poll loop dies fatally invokes `on_fatal_error` with the error before `run()` returns, and a throwing hook does not mask the original failure.

### R95: Provide a Real-History and Multi-History Replayer Surface (Medium)

**Defect.** `Test/WorkflowReplay.pm` is an activation-pushing harness keyed to one `workflow_class` (`:14`) with no history-JSON input, no batch replay, and no aggregated result type; R43 covers only the truthfulness of its nondeterminism claim, not replaying a downloaded history or batch replay with aggregated failures.
(Parity audit, worker finding 4; Python `worker/_replayer.py:110,138,166`, Perl `Test/WorkflowReplay.pm`. Confidence: medium.)

**Root cause.** The replay harness was built for internal activation tests, not real histories.

**Required behavior.** A public replayer accepts real `WorkflowHistory` objects (from fetched or JSON-loaded history), exposes `from_json` construction, and replays a stream of histories returning a per-history result; nondeterminism surfaces as a per-history failure.
This is the resolved direction, not harness-only; it pairs with R43, which makes the nondeterminism check real.

**Acceptance criteria.**
- Replaying a downloaded multi-event history JSON returns a result per history, with a mutated history producing a Nondeterminism failure in its result.
- `from_json` reconstructs a history that replays identically to the fetched form.

### Parity: Low

### R96: Add an Activity Context-Aware Logger (Low)

**Defect.** No activity logger surface exists in `Activity.pm` or `Activity/Context.pm`; Python's logger embeds activity id, type, attempt, namespace, task queue, and workflow ids into every log line.
(Parity audit, activity/conversion finding 6; Python `activity.py:479-537`, Perl `Activity/Context.pm`. Confidence: low, partly a Perl-ecosystem-idiom question.)

**Root cause.** Perl has no single standard logging framework, so no context logger was shipped.

**Required behavior.** The activity context exposes a logging-detail accessor (activity id, type, attempt, namespace, task queue, and the workflow ids) plus a documented pattern for attaching those details to the caller's logger (for example `Log::Any`); the SDK does not mandate a logging framework.
This is the resolved direction, chosen because Perl has no single standard logger.

**Acceptance criteria.**
- A test asserts the context detail accessor yields the documented field set for the running activity.
- The POD documents the pattern for wiring the details into the caller's logger.

### R97: Document the Legacy Build-ID Worker-Versioning APIs as a Deliberate Deviation (Low)

**Defect.** The three legacy build-id client RPCs are absent (all Perl versioning code is worker-side): `update_worker_build_id_compatibility`, `get_worker_build_id_compatibility`, `get_worker_task_reachability`.
(Parity audit, client finding 5; Python `_client.py:2770,2801,2832`, Perl `Client.pm`. Confidence: low: all three are deprecated in Python, superseded by the deployment-based versioning Perl already implements.)

**Root cause.** The legacy build-id API predates deployment versioning and was not ported.

**Required behavior.** The three legacy build-id client RPCs are not ported.
This is the resolved decision: they are deprecated in Python and superseded, so the surface is not worth implementing (spec §0 allows a documented surface deviation).
A Client POD note records the deliberate omission and points to the deployment-based versioning Perl already implements as the supported path.

**Acceptance criteria.**
- A Client POD section names the three omitted APIs and the deployment-based replacement; xt pod coverage stays green.
- A test asserts the deployment-versioning path is exercised and green.

## Component Boundaries

Each requirement is independently implementable, with these batching and ordering notes:

- R1 and R21 share the runtime shutdown pass; one ordering test covers barrier, pending-future failure, and free.
- R4, R5, R19, and R62 rework the `Activity/Pool.pm` fork channel; R18 adds its reverse direction; design the channel once.
- R8 through R10 land as one cluster with reproduce-first replay tests; R11 lands after them; R39, R40, and R51 close behind.
- R12, R52, and R53 form the cancellation-type test file.
- R22, R41, and R42 are one tracing unit of work; R23 and R50 one cancellation-future unit.
- R27 and R38 both touch the `CORE::GLOBAL` override lifecycle; decide the install point once.
- R33, R46, R47, and R48 share the Test helper Future-state fixes; R3 shares their test file.
- R34 and R61 close together if the port fix removes Net::EmptyPort.
- R56, R57, R58, and R59 are the converter batch; R64, R65, and R66 the POD pass.
- R70 runs last, after the replay harness gains the R8-cluster capabilities.

## Verification

The cycle is done when:

1. Every acceptance criterion above has a passing test, observed failing first where behavior changed.
2. The full suite passes: `prove -lj4 t` and `prove -lj4 xt` under `sdk/`, `cargo test` in the shim, `dzil test` per touched distribution, all under the CLAUDE.md memory guard.
3. Every memory-safety item (R1, R2, R3, R16, R28) carries its committed guard-assertion test with the code trace in comments, per Global Requirement 5.
4. The step-45 probes cited above exist as committed tests under `sdk/t/`; the scratchpad originals are not referenced anywhere.
5. The updates.t parallel flake (R34) no longer reproduces across ten `prove -lj4 t` runs.

## Review Record

Kept for auditability of the step-45 verification (`../../.ai-sessions/step-45-sdk-perl-verified.md`).

**Refuted candidate (no requirement issued):**

- L27: claimed Perl diverges from Python by not re-polling updates on long-poll DEADLINE_EXCEEDED.
  Python raises WorkflowUpdateRPCTimeoutOrCancelledError rather than re-polling; the SDKs differ only in exception type, and no parity defect exists.

**Sub-claim refutations inside confirmed findings (the parent requirements stand, narrowed):**

1. Finding R6 (requirement R7): the sub-claim that search attributes must pass the codec is refuted; Python also excludes search attributes from codec processing, so R7 requires the exclusion.
2. Finding R1 (requirement R22): the sub-claim that `durable_scheduler_disabled` is dead code is refuted; it has a public caller in `Workflow/Unsafe.pm`.
3. Finding A12 (requirement R66): the sub-claim that `rpc_metadata` is undocumented is refuted; it is documented, and R66 covers only the genuinely missing entries.
4. Finding L26 (requirement R33): the unbounded-leak claim is narrowed; a connect timeout leaks at most one connection per occurrence.

**Cross-reference with the samples-perl review:**

Three items forwarded from the samples-perl verification (step 39) to this review are superseded by requirements here:

1. Forward 1, the OTel TracingInterceptor stub, is superseded by finding R1, requirement R22 in this spec (with R41 and R42 for its tests).
2. Forward 2, the single-shot shared cancellation future, is superseded by finding R2, requirement R23 (with R50 for coverage).
3. Forward 3, the false pre-scheduled-cancel comment at `Workflow/Runner.pm:1188-1193`, is superseded by finding R3, requirement R51; the R8 through R10 cluster additionally shows the emergent fallback the comment gestured at is itself defective.

The samples-perl remediation spec (branch portfolio-audit in that repo) should cite R22, R23, and R51 by these ids, and may cite R8 through R10 for the shared cancellation story.
