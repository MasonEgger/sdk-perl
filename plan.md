# sdk-perl Remediation Plan (R1-R97)

TDD blueprint for the remediation and feature-parity spec at `spec.md`.
The spec holds 97 requirements: R1-R70 are the step-45 verified defects (memory safety, cancellation semantics, wire format, test infrastructure, POD drift), and R71-R97 are the 2026-07-06 reference-SDK feature-parity gaps.
Every step reproduces the defect (or asserts the missing capability) with a failing test first, then implements the minimal fix, so each commit lands green and the repro ships as permanent coverage.

The steps use the spec's R-ids so `plan.md`, `todo.md`, and `spec.md` stay 1:1; merged ids (for example `R8-R10`, `R12+R52+R53`) are the spec's Component-Boundaries clusters landing as one story.
The prior live-hardening plan (B0-B13, built from `sdk-perl-issues-from-samples.md`) is archived at `.ai-sessions/live-hardening/`.

## Prime Directives

1. **Reproduce before fixing, inside each step.** No fix is written until a RED test fails for the documented reason. Reproduction and fix land in the SAME commit, so the suite is always green and the repro is permanent coverage.
2. **Fix by root cause, honor the clusters.** The spec's Component Boundaries batch related requirements (shutdown pass, pool fork-channel, post-cancel cluster, cancellation-type file, tracing unit, converter/POD batches). A merged step is one story with one or more repros.
3. **Replay over live where deterministic.** Command-sequence and workflow-context behavior go in `sdk/t/replay/` (offline, no server). Use `sdk/t/integration/` only for genuine timing/live paths; crash/hang repros run subprocess-guarded via `sdk/t/lib/SubprocessGuard.pm`. Unit tests go in `sdk/t/unit/`, author/POD tests in `sdk/xt/`.
4. **Memory-safety items follow Global Requirement 5.** R1, R2, R3, R6, R16, R28 (and R29's cycle) where a race is not deterministically executable: the guard exists in code, a committed test asserts the guard's observable ordering or presence, and the test comments carry the code trace.
5. **Parity to Python source, verified at implementation time.** R71-R97 implement to `../sdk-python` behavior per spec §0; the GREEN checks the cited Python file, not memory.
6. **Every commit is green; test only your logic.** RED phases test the defect behavior and the fix's observable contract (emitted command, completion outcome, codec touch, typed error, interceptor invocation), never framework/library/language behavior.
7. **Shim changes follow the memory guard.** Any `ext/temporalio-perl-bridge/src/lib.rs` change uses `CARGO_BUILD_JOBS=2`, foreground builds, then `cargo test`, cbindgen regen, and Alien rebuild. Every gate runs under the CLAUDE.md memory guard.
8. **POD in the same change.** A fix that alters public behavior updates the POD in the same commit; `prove -lj4 xt` stays green.

## Current Status

### Phase P1: Memory Safety and Shutdown
- [ ] R1+R21 Runtime shutdown drain barrier and pending-future failure
- [ ] R2 Guard connection free against a dead runtime
- [ ] R3 Stop freeing the DevServer handle on the timeout path
- [ ] R28 Stop writing through a COW-shared tag buffer
- [ ] R16 Make evict iteration safe against sibling deletion

### Phase P2: Pool Fork-Channel Rework
- [ ] R4 Make activity pool state per-instance
- [ ] R5 Preserve error identity across the pool fork boundary
- [ ] R18+R19 Pool fork-channel: live heartbeat relay and cancel delivery
- [ ] R30 Close inherited gRPC descriptors in pool children
- [ ] R62 Stop masking pool and worker error causes

### Phase P3: Wire Format and Codec
- [ ] R6 Fix wide-character corruption in RawBytes at the FFI boundary
- [ ] R7 Extend the payload codec boundary to the full v0.2 surface

### Phase P4: Post-Cancel Corruption Cluster
- [ ] R8-R10 Post-cancel corruption cluster
- [ ] R11 Always send a completion for a failed activation
- [ ] R39 Add the missing on_cancel hook to child-workflow signals
- [ ] R51 Correct the pre-scheduled-cancel comment in Runner
- [ ] R40 Cover the post-cancel paths in the replay suite (close last)

### Phase P5: Cancellation Semantics
- [ ] R12+R52+R53 Cancellation-type test file
- [ ] R13 Keep query and update responses on failure completions
- [ ] R14+R15 Route workflow-fail options to live runners
- [ ] R17 Settle updates from cancelled handler futures without croaking
- [ ] R23+R50 Shared cancellation future survives wait_any + ChildCancellation tests
- [ ] R24 Enforce read-only context and writability asserts uniformly
- [ ] R20 Isolate exceptions per entry in the callback drain loop

### Phase P6: Workflow and Client Semantics
- [ ] R25 Send search_attributes and versioning_intent on continue-as-new
- [ ] R26 Deliver init signals before the main routine starts
- [ ] R27+R38 Determinism-guard install point and override accountability
- [ ] R29 Break the start-future ownership cycle in handles
- [ ] R31 Honor pending futures from custom slot suppliers
- [ ] R32 Implement Nexus cancel_task
- [ ] R36 Complete the workflow info() surface
- [ ] R35 Validate activity options at the call site
- [ ] R44 Unify unknown-option strictness on the client surface
- [ ] R55 Raise typed errors for missing workflow-context arguments
- [ ] R37 Wire or reject start_workflow extended options

### Phase P7: Test Infrastructure and Tracing
- [ ] R33+R46+R47+R48 DevServer and Test-helper Future-state fixes
- [ ] R34+R61 Remove the ephemeral-port race and fix the Net::EmptyPort dependency phase
- [ ] R49 Register dev-server teardown in END blocks
- [ ] R43 Make WorkflowReplay's nondeterminism claim true or scoped
- [ ] R45 Revive the dead Nexus integration test
- [ ] R22+R41+R42 OpenTelemetry TracingInterceptor and wired tests
- [ ] R70 Convert offline-skipping repro guards to replay tests (close last)

### Phase P8: Converter, POD, and Parity Edges
- [ ] R56-R59 Converter batch
- [ ] R64-R66 POD pass
- [ ] R54 Ship the promised workflow memo and search_attributes readers
- [ ] R60 Align metric-drop behavior with its documentation
- [ ] R63 Accept the spec-promised workflow argument forms in start_workflow
- [ ] R67 Map and validate query reject_condition
- [ ] R68 Accept non-Temporalio causes in exception chaining
- [ ] R69 Close the four verified cross-SDK divergences

### Phase P9: Parity — Interceptor and High-Value Gaps
- [ ] R71 Wire and invoke the workflow-outbound interceptor chain
- [ ] R72 Add the activity-outbound interceptor and wire ActivityInbound.init
- [ ] R73 Add the Nexus operation inbound interceptor role
- [ ] R74 Carry ApplicationError next_retry_delay through exception and failure proto
- [ ] R75 Support encode_common_attributes on the failure converter
- [ ] R76 Expose activity cancellation details and reason
- [ ] R77 Add workflow.uuid4 deterministic UUID
- [ ] R78 Carry a summary on timers, sleep, and wait_condition timeouts
- [ ] R79 Expose per-activation workflow info accessors
- [ ] R80 Add the max_concurrent_nexus_tasks worker kwarg
- [ ] R81 Add fairness_key and fairness_weight to Priority
- [ ] R82 Encode static_summary and static_details on the schedule action

### Phase P10: Parity — Medium and Low
- [ ] R83 Expose a user-facing metric meter in workflow, activity, and nexus context
- [ ] R84 Provide worker-shutdown detection inside activities
- [ ] R85 Complete activity Info with priority and retry_policy
- [ ] R86 Support runtime signal, query, and update handler registration
- [ ] R87 Honor per-handler HandlerUnfinishedPolicy
- [ ] R88 Expose last-completion-result and last-failure
- [ ] R89 Restore dropped Nexus handler-context capabilities
- [ ] R90 Implement lazy client connections
- [ ] R91 Expose raw service clients on the client
- [ ] R92 Add WorkflowHandle get_update_handle
- [ ] R93 Honor a client-level default query reject condition
- [ ] R94 Add an on_fatal_error worker hook
- [ ] R95 Provide a real-history and multi-history replayer surface
- [ ] R96 Add an activity context-aware logger
- [ ] R97 Document the legacy build-ID worker-versioning APIs as a deliberate deviation

---

## Phase P1: Memory Safety and Shutdown

R1-R3 are the memory-safety cluster (lifetime races across the FFI boundary), all analysis-confirmed, so all carry Global Requirement 5 criteria. R28 and R16 are memory-safety but probe-executable (ordinary test path).

### Step R1+R21: Runtime Shutdown Drain Barrier and Pending-Future Failure

**NOTE**: Findings L1 (`Runtime.pm:252-253`, plus shim trampolines `ext:1684-1689`, `ext:206-227`, `ext:368-392`) and L18 (`Core/Callback.pm:250, 472-477`). Both are memory-safety / hang races that carry Global Requirement 5 criteria. One shutdown pass covers both: a single unit ordering test asserts barrier-then-fail-then-free. Not shim-touching on the Perl side, but `cargo test` must cover any shim-side counterpart under the shim protocol.

```text
1. RED: Write unit tests first (GR5 guard-assertion, not an executed race):
   - Create sdk/t/unit/runtime-shutdown-drain.t:
     - Register a synthetic outstanding callback on the runtime, then drive shutdown; assert the completion-queue free is deferred until that callback resolves or is failed (spy/order log on the free vs. the callback settle).
     - Register a pending Core::Callback future, shut the runtime down, and assert the future fails with a typed shutdown error within the test timeout (not a hang).
     - Assert the single observable order barrier -> fail-pending -> queue-free (one ordering test spanning R1 and R21).
     - Test comments carry the code trace: Runtime.pm:252-253, the ext: trampoline paths (1684-1689, 206-227, 368-392), and Core/Callback.pm:250,472-477.
2. GREEN: minimal implementation:
   - Edit Core/Callback.pm around :250,:472-477 to expose an outstanding-callback count/registry and a fail_all_pending($shutdown_error) that settles every $pending future with a typed shutdown error.
   - Edit Runtime.pm:252-253 shutdown path to (a) wait on the drain barrier (outstanding count reaches zero via the existing eventfd drain), then (b) fail all pending callback futures, then (c) free the completion queue.
   - Add a typed shutdown error class (or reuse the existing runtime-shutdown error) for the failed futures.
3. REFACTOR: Centralize the shutdown sequence into one ordered helper so every shutdown path invokes barrier->fail->free identically; add a comment block citing findings L1 and L18.
4. Verify: R1 criteria (barrier exists and is invoked before free, order assertion + trace comment, free deferred until the synthetic callback settles); R21 criteria (pending future fails with shutdown error within timeout); cargo test green for the shim-side counterpart; full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R2: Guard Connection Free Against a Dead Runtime

**NOTE**: Finding L2 (`Client/Connection.pm:50-66` close and DESTROY calling `client_free` at `Core/FFI.pm:606-608` with no runtime-liveness check). Memory-safety (use-after-free), analysis-confirmed, carries Global Requirement 5 criteria. Unit test. Not shim-touching.

```text
1. RED: Write unit tests first (GR5 guard-assertion):
   - Create sdk/t/unit/connection-free-guard.t:
     - Destroy the runtime first, then explicitly close the connection; assert the process does not crash and client_free is NOT called (spy/logging assertion on the FFI call).
     - Destroy the runtime first, then let the connection go through DESTROY; assert the same (no client_free, no crash).
     - Test comments carry the code trace: Client/Connection.pm:50-66 and Core/FFI.pm:606-608.
2. GREEN: minimal implementation:
   - Edit Client/Connection.pm:50-66 (both close and DESTROY): either hold a strong reference keeping the runtime alive until client_free returns, or check runtime liveness before the FFI free and, when the runtime is gone, release only Perl-side state and skip client_free.
3. REFACTOR: Factor the liveness-guarded free into one private method both close and DESTROY call; comment cites finding L2.
4. Verify: guard present on both close and DESTROY (code-trace assertion); explicit-close-after-shutdown and DESTROY-after-shutdown both skip client_free and do not crash; full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R3: Stop Freeing the DevServer Handle on the Timeout Path

**NOTE**: Finding L3 (`Test/DevServer.pm:232` frees the handle via `Core/FFI.pm:625-628` on the shutdown-timeout path while core still borrows it). Memory-safety (use-after-free), analysis-confirmed, carries Global Requirement 5 criteria. Unit test; the DevServer shutdown test file also hosts R46 and R33 cases (Phase P7). Not shim-touching.

```text
1. RED: Write unit tests first (GR5 guard-assertion):
   - Create sdk/t/unit/devserver-shutdown-timeout.t:
     - Force the timeout arm (mock or stalled shutdown bridge future) and assert the handle free is deferred to a continuation on the still-pending bridge future, or skipped with a logged warning (spy on free_ephemeral / handle free).
     - Assert no code path frees the handle while the shutdown bridge future is still pending.
     - Test comments carry the code trace: Test/DevServer.pm:232 and Core/FFI.pm:625-628.
2. GREEN: minimal implementation:
   - Edit Test/DevServer.pm:232 timeout arm: instead of freeing immediately, attach the free to an on_ready/on_done continuation of the pending bridge future, or deliberately leak the handle with a logged warning on timeout.
3. REFACTOR: Isolate the deferred-free continuation into one helper; comment cites finding L3 and notes the relationship to R46/R33.
4. Verify: no free while the bridge future is pending (code-trace assertion); forced-timeout unit test shows the free deferred or skipped; full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R28: Stop Writing Through a COW-Shared Tag Buffer

**NOTE**: Finding L4, probe `verify-45/memsafe-infra/cow_tag.pl` (the 1-byte tag slot at `Core/Callback.pm:362-363` and `Worker/SlotSupplierRegistry.pm:69-70` shares its COW PV with the `"\0"` literal; shim write `ext:868` corrupts siblings). Memory-safety but probe-executable: ordinary test path, no Global Requirement 5 fallback. Not shim-touching (Perl-side copy-forcing).

```text
1. RED: Write a unit test first (committed adaptation of the step-45 probe):
   - Create sdk/t/unit/cow-tag-buffer.t (adapted from verify-45/memsafe-infra/cow_tag.pl):
     - Drive a shim write through the tag slot and assert an independently created "\0" scalar remains unchanged (no COW sibling corruption).
     - Include an audit note listing the checked scalar_to_buffer write sites (Core/Callback.pm:362-363, Worker/SlotSupplierRegistry.pm:69-70).
2. GREEN: minimal implementation:
   - Edit Core/Callback.pm:362-363 and Worker/SlotSupplierRegistry.pm:69-70: force a private, non-COW allocation of each tag buffer before scalar_to_buffer (bust COW) so the shim writes into private memory.
3. REFACTOR: Add a small helper that returns a private writable byte buffer and route both write sites through it; comment cites finding L4.
4. Verify: probe adaptation shows the independent "\0" scalar untouched after the shim write; audit note enumerates the write sites; full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R16: Make Evict Iteration Safe Against Sibling Deletion

**NOTE**: Finding L6, probes `verify-45/runner-misc/probe_l6_freed_iteration.pl` and `probe_l6_self_delete.pl` (evict iterates `values %pending` aliased at `Workflow/Runner.pm:1532-1538`; cancel continuations delete siblings at `:2199`, `:2212`, causing "Use of freed value in iteration"). Memory-safety but probe-executable: ordinary test path. Replay test. Not shim-touching.

```text
1. RED: Write a replay test first (committed adaptation of the freed-iteration probe):
   - Create sdk/t/replay/evict-sibling-delete.t (adapted from probe_l6_freed_iteration.pl):
     - Drive an evict whose cancel continuation deletes a not-yet-visited sibling pending entry; assert no "Use of freed value in iteration" croak and that the eviction completion is sent.
     - Cover the self-delete case (own-entry deletion, shown survivable) alongside the sibling case as the RED assertion.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:1532-1538: iterate a stable snapshot (a copied key or value list of %pending) instead of the aliased values, so continuations may delete any entry safely.
3. REFACTOR: Comment the snapshot with the code trace citing :1532-1538 and the wait_any sweeps at :2199 and :2212; carry the probe's finding note.
4. Verify: sibling-delete evict completes without the croak and sends the eviction completion; self-delete still survivable; full prove -lj4 t green under the CLAUDE.md memory guard.
```

---

## Phase P2: Pool Fork-Channel Rework

R4, R5, R18, R19, and R62 rework the `Activity/Pool.pm` fork channel. Design the channel once: R4 lays down the per-instance state hand-off, R5 adds structured error data over it, R18+R19 add the bidirectional side channel (heartbeat up, cancel down), and R62 preserves causes across the boundary. R30 closes inherited fds in the same fork setup.

### Step R4: Make Activity Pool State Per-Instance

**NOTE**: Finding L12, probe `verify-45/pool-payload/probe_pool_globals.pl` (`Activity/Pool.pm:29-38, 71-75, 150-151` publish registry/FD/module lists into `main::` package globals; a second worker clobbers the first). This step lays down the per-instance channel that R5/R18/R19 build on. Prove test. Not shim-touching.

```text
1. RED: Write a prove test first (committed adaptation of the globals probe):
   - Create sdk/t/unit/pool-per-instance.t (adapted from probe_pool_globals.pl):
     - Construct two pools with distinct registries in one process; dispatch through pool A and assert pool A's own activity runs (not pool B's).
     - Grep-probe assertion: no main:: globals remain in Activity/Pool.pm for registry, FD, or module hand-off.
2. GREEN: minimal implementation:
   - Edit Activity/Pool.pm:29-38, 71-75, 150-151: replace the ADJUST-block main:: globals with per-instance state (closure capture / init args / keyed storage on the pool object) so each child reads its own pool's registry, FD list, and module list. This is the one-time redesign of the fork state hand-off that R5/R18/R19 extend.
3. REFACTOR: Name and document the per-instance channel structure so R5 (structured errors) and R18/R19 (bidirectional side channel) attach cleanly; comment cites finding L12.
4. Verify: two-pool dispatch runs pool A's activity; grep shows no main:: registry/FD/module globals; full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R5: Preserve Error Identity Across the Pool Fork Boundary

**NOTE**: Finding L14, probe `verify-45/pool-payload/probe_pool_error.pl` (`Activity/Pool.pm:187` and `:130` stringify child exceptions; `Worker/ActivityDispatcher.pm:307-314` rewraps as a generic retryable ApplicationError, so a non-retryable failure retries forever). Extends the R4 fork channel to carry structured error data. Python parity for the rebuilt failure shape (verify against `../sdk-python`). Prove test. Not shim-touching.

```text
1. RED: Write a prove test first (committed adaptation of the pool-error probe):
   - Create sdk/t/unit/pool-error-identity.t (adapted from probe_pool_error.pl):
     - Throw a non-retryable Temporalio::Exception::Application from a pooled sync activity; assert the parent-side failure is non-retryable with the original error type and details.
     - Throw a plain die; assert it maps to a retryable ApplicationError with the message intact.
2. GREEN: minimal implementation:
   - Edit Activity/Pool.pm:187 and :130 to serialize structured error data (class, error type, non_retryable, details, cause chain) across the channel instead of a bare string, using the failure-converter shape as the carrier.
   - Edit Worker/ActivityDispatcher.pm:307-314 to rebuild the original failure semantics from the structured data instead of rewrapping the string as a generic retryable ApplicationError.
3. REFACTOR: Route both stringify sites through one structured-error encode/decode pair on the R4 channel; comment cites finding L14 and the verified Python parity source.
4. Verify: non-retryable ApplicationError returns non-retryable with type and details; plain die returns retryable with message; full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R18+R19: Pool Fork-Channel: Live Heartbeat Relay and Cancel Delivery

**NOTE**: Findings L13 (`Activity/Pool.pm:114-124, 172-174`: heartbeats relayed only after the body completes) and L15 (`Worker/ActivityDispatcher.pm:280`; `Activity/Pool.pm:161-162`: cancel is a one-shot boolean captured at dispatch). One bidirectional side-channel design serves both: child->parent for heartbeats, parent->child for cancel. Prove tests plus a skip_all-offline integration test. Not shim-touching.

```text
1. RED: Write prove and integration tests first:
   - Create sdk/t/unit/pool-live-heartbeat.t:
     - Run a pooled activity that heartbeats then blocks; assert the parent observes the heartbeat BEFORE the body returns (bounded relay latency).
   - Create sdk/t/integration/pool-heartbeat-timeout.t (skip_all offline):
     - A compliant long-running sync activity that heartbeats does not hit a heartbeat timeout.
   - Create sdk/t/unit/pool-live-cancel.t:
     - Cancel a running pooled activity; assert the child observes cancellation (cancellation future / is_cancelled) and the activity resolves cancelled.
2. GREEN: minimal implementation:
   - Extend the R4 fork channel to a two-directional protocol on Activity/Pool.pm:114-124, 172-174 (live heartbeat relay child->parent while the body runs) and Activity/Pool.pm:161-162 + Worker/ActivityDispatcher.pm:280 (deliver a later cancel parent->child, surfaced through the activity Context, replacing the one-shot boolean).
3. REFACTOR: Consolidate both directions into the single fork-protocol module introduced in R4; comment cites findings L13 and L15 and notes the two requirements share one channel.
4. Verify: parent observes the heartbeat before the body returns; heartbeat-timeout does not fire for a compliant activity (integration, offline-skipped); a running pooled activity observes cancel and resolves cancelled; full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R30: Close Inherited gRPC Descriptors in Pool Children

**NOTE**: Finding L16 (`Worker.pm:633`; `Activity/Pool.pm:49-56`: pool children inherit core/client gRPC socket fds; the CLAUDE.md architecture rule requires closing inherited FDs). Prove test with Linux `/proc/self/fd` enumeration (skip on other platforms). Not shim-touching.

```text
1. RED: Write a prove test first:
   - Create sdk/t/unit/pool-close-inherited-fds.t (skip on non-Linux):
     - Fork a pool child and assert via /proc/self/fd (or fd counting) that inherited core/client gRPC sockets are closed in the child while the pool channel fds stay open.
2. GREEN: minimal implementation:
   - Edit Activity/Pool.pm:49-56 (fork setup) and coordinate with Worker.pm:633: after fork, enumerate and close every inherited core/client descriptor, keeping only the pool channel fds.
3. REFACTOR: Factor the fd-closing sweep into one post-fork routine that whitelists the pool channel fds; comment cites finding L16 and the CLAUDE.md close-inherited-FDs rule.
4. Verify: child shows core/client sockets closed and the pool channel open (Linux fd assertion; skipped elsewhere); full prove -lj4 t green under the CLAUDE.md memory guard.
```

### Step R62: Stop Masking Pool and Worker Error Causes

**NOTE**: Finding L32 (`Activity/Pool.pm:98-101` swallows a child `require` failure; `Worker.pm:576-577, :855-864` finalize die masks the saved error). Batched with the R4/R5 pool work. Unit tests. Not shim-touching.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/pool-worker-error-cause.t:
     - Force a pool-child require failure and assert the surfaced error carries the original message including the module name.
     - Force a finalize die while a saved error is present and assert the finalize failure attaches to (does not replace) the saved error's message.
2. GREEN: minimal implementation:
   - Edit Activity/Pool.pm:98-101 to surface the require failure with the module name instead of swallowing it.
   - Edit Worker.pm:576-577 and :855-864 so a finalize failure attaches to the saved error rather than masking it.
3. REFACTOR: Route both hand-off points through a preserve-cause pattern; comment cites finding L32.
4. Verify: original require message (with module name) present; finalize failure attached to the saved error; full prove -lj4 t green under the CLAUDE.md memory guard.
```

---

## Phase P3: Wire Format and Codec

### Step R6: Fix Wide-Character Corruption in RawBytes at the FFI Boundary

**NOTE**: Finding L21 (probe). Root at `Payload/RawBytes.pm:13-18` (accepts a UTF8-flagged wide scalar) and `Core/FFI.pm:522-527` (mixes character-length with UTF-8 byte buffers; probe measured 34 vs 36 bytes). Memory-safety at the FFI boundary, so Global Requirement 5 applies: the guard lives in code, a committed test asserts frame length equals bytes written, and the GREEN carries a code-trace comment. Unit test. Land early with the High band.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/rawbytes_ffi_bytes.t:
     - A RawBytes built from a wide-character scalar (a codepoint above U+00FF, e.g. U+2603) either round-trips with the emitted proto frame length equal to the byte count actually written to the FFI buffer, or raises the documented typed error; assert no silent length mismatch (the 34-vs-36 hazard).
     - The latin-1-range ambiguous case: a UTF8-flagged scalar whose codepoints are all <= 0xFF round-trips byte-identically.
     - The byte length used for framing equals length of the buffer handed to scalar_to_buffer for both a pure-ASCII payload and a payload containing embedded NULs.
2. GREEN: minimal implementation:
   - Edit Payload/RawBytes.pm:13-18 to enforce byte purity at construction: downgrade/encode input to bytes deterministically (or reject a wide scalar with a typed error), so the stored buffer is always bytes.
   - Edit Core/FFI.pm:522-527 so the framing length is computed from the byte buffer that is written, never from a character-semantics length.
3. REFACTOR: Audit every other scalar_to_buffer call site in Core/FFI.pm for the same character-vs-byte hazard (R28 owns the COW variant). Add a comment at the RawBytes boundary and the FFI framing site citing L21 and the invariant framed-length == bytes-written.
4. Verify: wide scalar round-trips or raises the typed error (frame==payload length assertion); latin-1 UTF8-flagged scalar round-trips byte-identically; full prove -lj4 t green (and prove -lj4 xt if POD moves) under the memory guard.
```

### Step R7: Extend the Payload Codec Boundary to the Full v0.2 Surface

**NOTE**: Finding R6. The codec boundary in `Worker/WorkflowDispatcher.pm:200-249` and `:170-181` covers only the v0.1 activation surface, so a configured encryption codec is silently defeated on the v2 paths. Largest single requirement: drive it surface-by-surface, one replay test per surface, so a regression pinpoints the path. Search attributes stay codec-free (Review Record sub-claim 1). Replay tests.

```text
1. RED: Write replay tests first, one file per surface, each using a marker codec that tags every payload it touches (assert the tag on encode outbound and its removal on decode inbound):
   - sdk/t/replay/codec_update_input.t: update input payloads decoded inbound before the handler runs.
   - sdk/t/replay/codec_child_nexus_results.t: child-workflow and nexus operation results decoded inbound.
   - sdk/t/replay/codec_failure_payloads.t: failure payloads (encoded_attributes / details) pass through the codec both directions.
   - sdk/t/replay/codec_memo_headers.t: memo and header payloads encoded outbound and decoded inbound.
   - sdk/t/replay/codec_update_query_responses.t: update and query responses encoded outbound.
   - sdk/t/replay/codec_continue_as_new_args.t: continue-as-new arguments encoded outbound.
   - sdk/t/replay/codec_local_activity_args.t: local-activity input arguments encoded outbound.
   - sdk/t/replay/codec_signal_external_args.t: signal-external-workflow arguments encoded outbound.
   - sdk/t/replay/codec_upserts.t: upsert-memo payloads pass through; assert upsert search-attribute payloads are NOT codec-wrapped (marker absent).
   - In each file also assert the SA negative where that surface carries SAs, so the exclusion is pinned per path.
2. GREEN: minimal implementation:
   - Edit Worker/WorkflowDispatcher.pm:200-249 and :170-181 to route each newly-covered payload through the configured codec in the correct direction, matching the Python codec boundary, and to skip search-attribute payloads.
   - Extend the encode/decode helpers surface by surface until every RED file goes green.
3. REFACTOR: Collapse the per-surface encode/decode calls behind a single directional helper so future v2 surfaces cannot bypass it; comment cites R6 and lists the covered surfaces plus the SA exclusion. Update the codec section of the Converter POD.
4. Verify: encode on every outbound surface, decode on every inbound one (marker assertions across the nine files); search-attribute payloads not codec-wrapped (negatives); Converter POD lists the covered surfaces (prove -lj4 xt); full prove -lj4 t green under the memory guard.
```

---

## Phase P4: Post-Cancel Corruption Cluster

R8-R10 land as one cluster with reproduce-first replay tests; R11 lands after them; R39 and R51 close behind; R40 is the coverage ledger and closes last.

### Step R8-R10: Post-Cancel Corruption Cluster

**NOTE**: Findings R4 / R4b / R4c (three ways the runner destroys a workflow that acts after a cancel). Roots in `Workflow/Runner.pm`: R8 at `:1709` (AWAIT_CLONEd `_ActivityFuture`) swept by the fallback cancel at `:2276-2278`, later resolution dies "already failed and cannot be ->done" at `:3297-3306`; R9 at `:2851` (`->result` croaks on a cancelled plain Future in `_build_completion`); R10 at `:2188-2278` (`_apply_cancel_workflow` never sweeps `%pending_external_signals`/`%pending_external_cancels` populated at `:934`, `:994`, `:2009`). One clustered step, three reproduce-first replay repros adapted from `verify-45/cancel-core/`, shared GREEN. Replay tests.

```text
1. RED: Write replay tests first, three reproduce-first repros adapted from the step-45 verify-45/cancel-core/ probes (commit the adapted probe before the fix), each using the WfDef-module + pushed-activation harness pattern:
   - sdk/t/replay/repro_post_cancel_cleanup.t (R4 probe): ScheduleActivity + CancelWorkflowExecution in one activation; the body catches Cancelled and awaits a cleanup activity. RED: the "already failed and cannot be ->done" death on the later activity resolution.
   - sdk/t/replay/repro_cancel_plain_future.t (R4b probe): park the body on a plain Future, deliver cancel_workflow. RED: ->result croaks at Runner :2851 and no completion is produced.
   - sdk/t/replay/repro_cancel_ext_signal.t (adapt verify-45/cancel-core/probe_r4bc_ext_signal.t with WfDef/ExtSignalWait.pm): park on signal_external_workflow_execution, deliver cancel_workflow; add the external-cancel-map shape. RED: the probe dies inside push_activation because the pending external maps are never swept.
2. GREEN: shared minimal implementation in Workflow/Runner.pm:
   - R8: do not fail the main run future while the body is alive and awaiting post-cancel work; deliver Cancelled into the awaited point and let scheduled/awaited cleanup work resolve normally (guard the sweep at :2276-2278 against live post-cancel futures; stop the stale-resolution drop at :3297-3306 from killing a re-scheduled activity).
   - R9: in _build_completion near :2851, discriminate the cancelled state before ->result so a cancelled main run future maps to the CancelWorkflowExecution outcome, never a croak.
   - R10: in _apply_cancel_workflow (:2188-2278) also sweep %pending_external_signals and %pending_external_cancels, failing those futures with Cancelled exactly as the activity/timer/child maps.
3. REFACTOR: Unify the fallback's per-map sweep so every pending map (activity, timer, child, external-signal, external-cancel) is enumerated from one list; comment cites R4/R4b/R4c and describes the delivered-cancellation-then-continue mechanism.
4. Verify: R8 -> repro_post_cancel_cleanup.t asserts the cleanup activity command is emitted and its resolution completes the workflow, and the "already failed" death is gone; R9 -> repro_cancel_plain_future.t asserts a CancelWorkflowExecution completion (no die, no missing completion); R10 -> repro_cancel_ext_signal.t asserts the parked body observes Cancelled and returns with a completion for both external-signal and external-cancel shapes; full prove -lj4 t green under the memory guard.
```

### Step R11: Always Send a Completion for a Failed Activation

**NOTE**: Finding R5 (equal to L9); probe `verify-45/cancel-core/probe_r5_async_query.t`. Roots: `Worker/WorkflowDispatcher.pm:89-128` lets dies escape and `Worker/PollLoop.pm:46-50` warns-and-swallows, so the WFT is never completed and the workflow wedges until timeout on every retry; verified trigger sites in `Workflow/Runner.pm:2687, 2572, 1839, 1914, 2080-2081, 2151-2152, 2851`. Land AFTER R8-R10 so their RED tests fail for the right reason first. Replay plus subprocess-guarded fault-injection.

```text
1. RED: Write replay and subprocess-guarded tests first:
   - sdk/t/replay/failed_activation_completion.t: the probe scenario (a :Query handler returning a pending future) asserts a failed workflow-task completion is sent, not an unhandled die.
   - sdk/t/integration/failed_activation_no_wedge.t (subprocess-guarded via sdk/t/lib/SubprocessGuard.pm, skip_all offline): fault-injection, a workflow that dies inside a handler the runner currently mishandles; assert the WFT fails (a failed completion is emitted) rather than wedging or warning-and-swallowing.
2. GREEN: minimal implementation:
   - Edit Worker/WorkflowDispatcher.pm:89-128 to wrap activation processing in a catch-all that turns any die into a failed workflow-task completion (or eviction, per the core activation contract), Python-parity failure content.
   - Edit Worker/PollLoop.pm:46-50 so it no longer warns-and-swallows: the completion contract with core is honored on the failure path.
3. REFACTOR: Centralize the die-to-failed-completion mapping so the Runner.pm trigger sites funnel through it; comment cites R5 and names the completion contract.
4. Verify: failed completion sent instead of an unhandled die (failed_activation_completion.t); WFT fails rather than wedges (failed_activation_no_wedge.t); full prove -lj4 t green under the memory guard.
```

### Step R39: Add the Missing on_cancel Hook to Child-Workflow Signals

**NOTE**: Finding R10 (the child-signal arm; distinct from the R10 post-cancel sweep in the cluster step). Root: `_signal_child_workflow` at `Workflow/Runner.pm:908-936` lacks the on_cancel hook its external-signal sibling has at `:996-1010`, so a child signal cancelled in flight never emits CancelSignalWorkflow. Replay test, behind R8-R10.

```text
1. RED: Write replay tests first:
   - sdk/t/replay/child_signal_cancel.t:
     - Cancelling a pending child-workflow signal future emits the CancelSignalWorkflow command (parity with the external-signal arm).
     - Edge: a child signal that resolves before cancel emits no cancel command.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:908-936 to add the on_cancel hook to _signal_child_workflow, mirroring the external-signal sibling at :996-1010, so a cancelled pending future emits the cancel command.
3. REFACTOR: Factor the shared on_cancel-emits-cancel-command logic so the child and external signal arms cannot drift again; comment cites R10.
4. Verify: cancelling a pending child signal emits the cancel command; no double-emit when resolved first; full prove -lj4 t green under the memory guard.
```

### Step R51: Correct the Pre-Scheduled-Cancel Comment in Runner

**NOTE**: Finding R3 (equal to L31b). The comment at `Workflow/Runner.pm:1188-1193` claims a pre-scheduled-cancel mirror for activities and children that does not exist, and the nexus arm contradicts its own header comment. Comment-only: the real mechanism is the `_apply_cancel_workflow` fallback, which R8-R10 rewrites, so land AFTER R8-R10 and write the comment once against the fixed behavior.

```text
1. RED: Write a documentation-guard check first:
   - Add an assertion to sdk/t/unit/runner_comments.t (create if absent) that the Runner.pm:1188-1193 region no longer contains the stale "pre-scheduled cancel" phrasing (grep-style guard); this fails against the current comment.
2. GREEN: minimal change:
   - Edit Workflow/Runner.pm:1188-1193 so the comment describes the actual mechanism post-R8-R10 (the _apply_cancel_workflow fallback delivering cancellation), and fix the nexus arm so it no longer contradicts its own header comment.
3. REFACTOR: none beyond wording; ensure the comment cites finding R3 and the fixed fallback behavior.
4. Verify: comments match the shipped control flow (passing guard in runner_comments.t plus reviewer sign-off recorded in the fix commit message); full prove -lj4 t green under the memory guard.
```

### Step R40: Cover the Post-Cancel Paths in the Replay Suite

**NOTE**: Finding T8. The R4-family post-cancel paths ship untested; only the nexus pre-cancel case is covered (`sdk/t/replay/nexus.t:390`). This is the coverage ledger for the R8-R10 cluster and MUST close LAST in that cluster (after R8-R10, R11, R39, R51): the R8-R10 repros count toward it and this step fills the remaining arms. Replay tests.

```text
1. RED: Write the remaining post-cancel replay cases first, each in catch-and-cleanup and propagate shapes, one file per arm not already covered by the R8-R10 repros:
   - sdk/t/replay/post_cancel_child_workflow.t: child-workflow await, cancel delivered, both shapes.
   - sdk/t/replay/post_cancel_timer.t: timer await, cancel delivered, both shapes.
   - sdk/t/replay/post_cancel_local_activity.t: local-activity await, cancel delivered, both shapes.
   - Reference the activity arm as already covered by the R8-R10 repros so the ledger is complete across all four arms.
2. GREEN: no product code (the behavior is fixed by R8-R10); if any new case fails, the failure is a real gap traced back to the cluster, not fixed here.
3. REFACTOR: Add a header in each new file mapping it to finding T8 and the arm it covers; keep the four-arm ledger visible.
4. Verify: t/replay/ contains post-cancel cases for the four arms in both shapes (three new files plus the activity-arm R8-R10 repros); full prove -lj4 t green under the memory guard.
```

---

## Phase P5: Cancellation Semantics

### Step R12+R52+R53: Cancellation-Type Test File (Regular and Local-Activity Wait Types)

**NOTE**: Findings R7 (R12), L8 (R52), L10 (R53). Regular-activity cancel arm at `Workflow/Runner.pm:513-537` fails the future immediately on cancel and drops the stale core resolution (`:3297-3306`, `:1739`), ignoring WAIT_CANCELLATION_COMPLETED that the LA arm already honors (`:696-716`); evict's wait-honoring path parks wait-type LAs forever (`:1537`, `:711-716`, `:3347-3358`); the wait-type LA cancel has no at-most-once guard (`:711-716`, `:738-748`). Three defects share one replay test file. Verify WAIT_CANCELLATION_COMPLETED semantics against `../sdk-python`.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/cancellation_types.t:
     - R12: cancel a regular activity started with WAIT_CANCELLATION_COMPLETED; assert the future stays pending after the cancel request and resolves only when the resolution job arrives, carrying the delivered outcome.
     - R12: cancel a regular activity started with TRY_CANCEL; assert the future resolves cancelled immediately (unchanged).
     - R52: evict a run holding a wait-type local activity; assert the eviction completion is sent and the run releases (no parked-forever hang).
     - R53: double-cancel a wait-type LA in the same activation; assert exactly one RequestCancelLocalActivity command is emitted.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:513-537 (regular-activity cancel arm): under WAIT_CANCELLATION_COMPLETED, leave the future pending on cancel and resolve it from the delivered resolution job; stop discarding it as stale (:3297-3306, :1739). Keep TRY_CANCEL immediate.
   - Edit Workflow/Runner.pm:1537 (evict path): route evict through an unconditional-cancel path that ignores the LA cancellation type (:711-716, :3347-3358).
   - Edit Workflow/Runner.pm:711-716,:738-748: add a sent-flag keyed by LA sequence number so a second cancel is a no-op.
3. REFACTOR: Factor the regular- and local-activity cancel arms so both consult one wait-type helper; comment each site citing R7/L8/L10 and the Python-parity outcome note.
4. Verify: R12 pending-until-resolution and TRY_CANCEL-unchanged; R52 eviction-completes; R53 exactly-one-cancel-command; full prove -lj4 t green under the memory guard.
```

### Step R13: Keep Query and Update Responses on Failure Completions

**NOTE**: Finding R9. `Workflow/Runner.pm:3054` clears `@commands` when building a workflow-failure completion, dropping query and update responses accumulated in the same activation; the in-code comment claiming Python does the same is false. Replay test. Verify the exact Python behavior in `../sdk-python` before writing the assertion.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/failure_keeps_responses.t:
     - A workflow answers a query then dies in the same activation; assert the failure completion still carries the query response command.
     - A workflow emits an update response then dies in the same activation; assert the failure completion still carries the update response command.
     - State-mutating workflow commands (e.g. a scheduled timer/activity) are still dropped from the failure completion.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:3054: partition @commands and retain query/update-response commands while dropping state-mutating workflow commands when building the failure completion.
   - Correct the false in-code comment to state what Python actually does (cited from ../sdk-python).
3. REFACTOR: Extract a predicate (is_handler_response_command) used by the partition; comment cites R9 and the Python source location.
4. Verify: query-response-present, update-response-present, and mutating-command-dropped assertions pass; full prove -lj4 t green under the memory guard.
```

### Step R14+R15: Route workflow_failure_exception_types and nondeterminism_as_workflow_fail to Live Runners

**NOTE**: Findings A1 (R14) and ADJ2 (R15), one plumbing diff. `Worker.pm:459-460` misroutes `workflow_failure_exception_types` into core's workflow-TYPE field via `Worker/WorkflowDispatcher.pm:170-181` so it never reaches a live Runner (`Workflow/Runner.pm:90`); `nondeterminism_as_workflow_fail` is dropped the same way. The replay harness threads both correctly (`Test/WorkflowReplay.pm:81`), so live and replay diverge.

```text
1. RED: Write unit + replay tests first:
   - Create sdk/t/unit/dispatcher_failure_options.t:
     - Construct a live-path dispatcher/Runner with workflow_failure_exception_types set to a listed type and assert the constructed Runner receives that list (not core's workflow-TYPE field).
     - Same construction asserts nondeterminism_as_workflow_fail arrives at the Runner as the boolean set.
   - Create sdk/t/replay/failure_exception_types.t:
     - A workflow that dies with a listed exception type fails the workflow (not the task); an unlisted type fails the task.
     - A nondeterminism scenario fails the workflow when nondeterminism_as_workflow_fail is set and fails the task when it is not.
2. GREEN: minimal implementation:
   - Edit Worker.pm:459-460 and Worker/WorkflowDispatcher.pm:170-181: route both options into the live Runner constructor argument (matching Workflow/Runner.pm:90 and Test/WorkflowReplay.pm:81), not core's workflow-type field.
3. REFACTOR: Name the plumbing keys once at the dispatcher boundary so live and replay share them; comment cites A1/ADJ2 and the live/replay parity requirement.
4. Verify: unit test asserts both options reach the Runner; replay test asserts workflow-failure vs task-failure for both the listed-type and nondeterminism cases; full prove -lj4 t green under the memory guard.
```

### Step R17: Settle Updates from Cancelled Handler Futures Without Croaking

**NOTE**: Finding L7 (analysis; Future semantics from `verify-45/runner-misc/probe_l7_cancelled_result.pl`). Evicting a run with an in-flight async `:Update` croaks in `_settle_update`: the cancelled handler future passes the empty `->failure` check and then `->result` croaks (`Workflow/Runner.pm:1533, 2522-2525, 2610`). `_settle_update` handles done and failed but not cancelled futures.

```text
1. RED: Write replay + unit tests first:
   - Create sdk/t/replay/evict_pending_update.t: evict a run holding a pending async :Update whose handler future gets cancelled; assert no croak and that the eviction completion is sent.
   - Create sdk/t/unit/settle_update_states.t: drive the factored settle-update core across done, failed, and cancelled futures; assert each settles without dying and the cancelled state settles per the eviction contract (rejected or dropped).
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:2522-2525,:2610 (_settle_update): before calling ->result, discriminate a cancelled future (->is_cancelled) and settle the update per the eviction contract without touching ->result.
3. REFACTOR: Factor the done/failed/cancelled branch into a small settle-core sub the unit test calls directly; embed the probe's cancelled-future state table in the test comments; cite L7.
4. Verify: replay evict asserts no-croak + eviction-completes; unit test asserts all three future states settle cleanly; full prove -lj4 t green under the memory guard.
```

### Step R23+R50: Make the Shared Cancellation Future Survive wait_any (with Direct ChildCancellation Tests)

**NOTE**: Findings R2 (=A4=L31a) for R23 and T2 for R50; one cancellation-future unit of work. `Cancellation.pm:26-37` hands out a single shared `cancelled()` future guarded by `is_ready`; a `Future->wait_any` loser sweep cancels and permanently poisons it. `Activity/ChildCancellation.pm:21-34` clones the defect and has zero direct tests. The wait_any race is R23's RED; R50 adds the direct ChildCancellation coverage. RED adapts `verify-45/cancel-core/probe_r2_wait_any.pl`.

```text
1. RED: Write unit tests first (adapted from verify-45/cancel-core/probe_r2_wait_any.pl):
   - Extend sdk/t/unit/cancellation.t: race cancelled() inside Future->wait_any twice (two losing consumers), then cancel the Cancellation; assert a fresh consumer of cancelled() still observes cancellation (the shared future is not poisoned).
   - Create sdk/t/unit/child_cancellation.t (R50): cover construction and cancellation observation of Activity/ChildCancellation; repeat the wait_any-loser race and assert a later consumer still observes cancellation (the R23 RED test for this class).
2. GREEN: minimal implementation:
   - Edit Cancellation.pm:26-37: cancelled() returns a per-call derived future (or a ->without_cancel wrapper over the shared future) so a consumer's wait_any cancel cannot poison the source.
   - Edit Activity/ChildCancellation.pm:21-34: apply the same fix.
3. REFACTOR: Share one helper between the two classes if the derivation is identical; add POD to both documenting that cancelled() is safe to race in wait_any; comment cites R2/T2.
4. Verify: cancellation.t second-consumer-observes; child_cancellation.t construction, observation, and race assertions; xt POD green; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R24: Enforce Read-Only Context and Writability Asserts Uniformly

**NOTE**: Finding R8 (=L11). `patched()`, child-signal, external-signal, and external-cancel bypass `_assert_writable` (`Workflow/Runner.pm:417-436, :929, :989-991, :1031-1033`), and query handlers never enter a read-only context (`:2640-2705`), so a query can emit commands. Replay test, table-driven across the four bypassing APIs. Match Python's read-only enforcement.

```text
1. RED: Write a replay test first:
   - Create sdk/t/replay/query_readonly.t:
     - Table-drive a query handler that calls each of the four bypassing APIs (patched, child-signal, external-signal, external-cancel) and assert each raises the typed read-only error from within query (read-only) context.
     - Assert that outside query context (normal :Run) each of those APIs still works (writable-context behavior unchanged).
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:417-436,:929,:989-991,:1031-1033: add _assert_writable at each command-emitting site.
   - Edit Workflow/Runner.pm:2640-2705: run query-handler execution inside a read-only context (dynamically-scoped flag) that makes _assert_writable raise the documented typed error on any command emission.
3. REFACTOR: Table-drive the guard so new command-emitting APIs inherit it; comment cites R8 and the Python read-only parity.
4. Verify: each of the four APIs raises the typed read-only error inside query context; each still works in writable context; full prove -lj4 t green under the memory guard.
```

### Step R20: Isolate Exceptions Per Entry in the Callback Drain Loop

**NOTE**: Finding L17 (probe-verified mechanism). The completion drain loop (`Core/Callback.pm:322-331, 463-467`) has no per-entry exception isolation; one dying continuation aborts the loop and strands every later completion in the chunk.

```text
1. RED: Write a unit test first:
   - Extend sdk/t/unit/callback.t: enqueue a chunk of drained entries where a middle entry's continuation dies; assert every other entry's continuation still runs (later entries not stranded) and the death is captured/logged rather than propagated out of the loop.
2. GREEN: minimal implementation:
   - Edit Core/Callback.pm:322-331,:463-467: wrap each per-entry continuation invocation in its own eval; on death, log and continue to the next entry.
3. REFACTOR: Factor the guarded-invoke into one helper used by both drain sites; comment cites L17 and the blast-radius contract.
4. Verify: all non-dying entries ran despite the middle death, and the loop did not abort; full prove -lj4 t green under the memory guard.
```

---

## Phase P6: Workflow and Client Semantics

### Step R25: Send search_attributes and versioning_intent on Continue-as-New

**NOTE**: Finding R11. `Workflow/Runner.pm:2933-2980` drops `search_attributes` and `versioning_intent` from the continue-as-new command despite the POD and proto fields. Replay test. Check proto field names against `sdk/share/proto/`.

```text
1. RED: Write a replay test first:
   - Create sdk/t/replay/continue_as_new_options.t:
     - Continue-as-new with search_attributes and versioning_intent set; assert both fields appear in the emitted ContinueAsNewWorkflowExecution command with the caller's values.
     - Continue-as-new omitting both; assert the command keeps proto defaults (fields absent/default).
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:2933-2980: carry both options into the ContinueAsNewWorkflowExecution command when provided, using proto field names confirmed against sdk/share/proto/.
3. REFACTOR: Reuse the existing search-attribute encoding helper (shared with start/upsert) rather than re-encoding; comment cites R11 and the proto field path.
4. Verify: both-fields-present-with-values and omitted-keeps-defaults; full prove -lj4 t green under the memory guard.
```

### Step R26: Deliver Init Signals Before the Main Routine Starts

**NOTE**: Finding R12 (analysis). Signals in the initializing activation drain only after `:Run`'s synchronous prologue (`Workflow/Runner.pm:2317-2319, 1709, 1716`); Python runs handlers first, so signal-with-start behaves differently on Perl. Confirm the exact Python ordering against `../sdk-python` before encoding the assertion.

```text
1. RED: Write a replay test first:
   - Create sdk/t/replay/init_signal_ordering.t:
     - Deliver an initializing activation carrying a signal plus start-workflow; the signal handler sets a flag/appends to a list, and the main routine's prologue reads it. Assert the handler side effect is visible to the main routine's first statement (Python parity, ordering cited in the comment).
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:2317-2319,:1709,:1716: apply same-activation signal jobs before invoking the main routine's synchronous prologue (match the Python job-application order).
3. REFACTOR: Make the job-application order explicit/named so the signals-before-main contract is legible; comment cites R12 and the ../sdk-python ordering source.
4. Verify: handler-side-effect-visible-to-prologue; regression check that a signal delivered after start still works; full prove -lj4 t green under the memory guard.
```

### Step R27+R38: Determinism-Guard Install Point and Override Accountability

**NOTE**: Findings R13 (R27) and A15 (R38); both touch the `CORE::GLOBAL` override lifecycle, so decide the install point once. The guard is compile-order blind: `Worker.pm:139` installs at worker construction and `Workflow/DeterminismGuard.pm:67-69` only traps call sites compiled after installation; and `Worker.pm:106-111,:139-140` installs process-global overrides one-way with no uninstall and no documented residency. RED for R27 adapts `verify-45/runner-misc/probe_r13_compile_order.pl`. Note the cross-repo dependency: samples-perl R1 becomes satisfiable without load-order tricks.

```text
1. RED: Write subprocess-guarded integration + unit tests first:
   - Create sdk/t/integration/determinism_guard_load_order.t (adapted from verify-45/runner-misc/probe_r13_compile_order.pl, subprocess-guarded via t/lib/SubprocessGuard.pm): compile/register a workflow Definition whose module is loaded before worker construction; run it and assert the guard trips (traps time/rand) inside workflow context.
   - Extend sdk/t/unit/determinism_guard.t (R38): with a worker alive but outside workflow context, assert time and rand behave stock (the overrides are transparent passthroughs).
2. GREEN: minimal implementation:
   - Edit Workflow/DeterminismGuard.pm:67-69 and the Definition load path: install/arm the guard at Definition registration (or require-the-workflow-under-guard) so trapping does not depend on worker-construction compile order.
   - Edit Worker.pm:106-111,:139-140: keep the overrides transparent passthroughs outside workflow context; add the uninstall for the last-worker-destroyed case (or, if permanence is chosen, keep install here) consistent with the single install-point decision.
3. REFACTOR: Choose one install point (Definition load) and route both R27 and R38 through it; document the override residency/lifecycle in the Worker POD; comment cites R13/A15.
4. Verify: load-order integration test asserts the guard trips for a pre-loaded workflow; unit test asserts stock time/rand outside workflow context while a worker exists; POD lifecycle added; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R29: Break the Start-Future Ownership Cycle in Handles

**NOTE**: Finding L5 (probe `verify-45/runner-misc/probe_l5_cycle.pl`). `Workflow/ChildWorkflowHandle.pm:58` and `Workflow/NexusOperationHandle.pm:64` resolve the start future with the owning handle itself (`Workflow/Runner.pm:895-897`), creating an uncollectable cycle that pins the handle, its futures, and the Runner per child/nexus start. Probe-executable (weak-ref liveness check). RED adapts the probe.

```text
1. RED: Write unit tests first (adapted from verify-45/runner-misc/probe_l5_cycle.pl):
   - Create sdk/t/unit/handle_start_cycle.t:
     - Construct a ChildWorkflowHandle, resolve its start future, drop all strong refs, and assert (weak-ref liveness check) the handle's DESTROY runs (no uncollectable cycle).
     - Repeat for NexusOperationHandle.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:895-897 and the two handle classes (ChildWorkflowHandle.pm:58, NexusOperationHandle.pm:64): resolve the start future with a non-owning token, or weaken the back-reference, so the handle is not pinned by its own start future.
3. REFACTOR: If callers exchange a token for the handle, centralize that exchange; comment cites L5 and flags the same future-resolves-with-owner shape to watch elsewhere.
4. Verify: both handle classes' DESTROY-runs-after-drop weak-ref assertions pass; regression check that callers still obtain the handle from the start future; full prove -lj4 t green under the memory guard.
```

### Step R31: Honor Pending Futures from Custom Slot Suppliers

**NOTE**: Finding L19 (probe `verify-45/memsafe-infra/resolve_permit.pl`). A custom slot supplier returning a pending Future gets a fabricated instant permit 1 (`Worker/SlotSupplierRegistry.pm:102-117, 141-148`), so supplier backpressure becomes an unconditional grant. Check the shim-side reserve-timing expectation if the fix changes callback ordering.

```text
1. RED: Write a unit test first (adapted from verify-45/memsafe-infra/resolve_permit.pl):
   - Create sdk/t/unit/slot_supplier_pending.t:
     - Drive _resolve_permit with a supplier that returns a still-pending reserve future; assert no permit is issued while the future is pending.
     - Resolve the future with a supplier value; assert the issued permit carries that resolved value (not the fabricated default 1).
2. GREEN: minimal implementation:
   - Edit Worker/SlotSupplierRegistry.pm:102-117,:141-148: in _resolve_permit, defer the permit for a pending reserve future (attach a continuation) instead of fabricating permit 1; issue the permit only on resolution, carrying the supplier's value.
3. REFACTOR: Name the pending-vs-resolved branch clearly; comment cites L19 and notes the shim reserve-timing expectation checked/unchanged.
4. Verify: no-permit-while-pending and permit-matches-resolved-value; full prove -lj4 t green under the memory guard.
```

### Step R32: Implement Nexus cancel_task

**NOTE**: Finding L20. Nexus `cancel_task` is a silent no-op: `%running` is always empty (`Worker/NexusDispatcher.pm:109`), so the cancel lookup at `:93-98` never matches and `ack_cancel` (`:350-353`) is dead code. Extend the existing `t/replay/nexus.t` harness.

```text
1. RED: Write a replay test first:
   - Extend sdk/t/replay/nexus.t: dispatch a nexus task, then deliver a cancel_task for that operation; assert the operation's future is cancelled (the handler observes cancellation) and ack_cancel fires.
2. GREEN: minimal implementation:
   - Edit Worker/NexusDispatcher.pm:109 (and dispatch path): register each running nexus operation in %running keyed so the cancel lookup at :93-98 matches; on cancel_task, cancel the matching operation's future and send ack_cancel (:350-353); deregister on completion.
3. REFACTOR: Ensure register/deregister are paired (completion, failure, cancel all deregister) so the map does not leak; comment cites L20.
4. Verify: cancel_task-cancels-operation and ack_cancel-fires; regression check that a normal (uncancelled) nexus op still completes and deregisters; full prove -lj4 t green under the memory guard.
```

### Step R36: Complete the Workflow info() Surface

**NOTE**: Finding A5. `Workflow::info()` returns a bare hashref missing `workflow_id`, `attempt`, and `task_queue` (`Workflow/Runner.pm:391-407`), and the POD (`Workflow.pm:470-471`) links a class that does not exist. Check field naming against Python's `workflow.info()`.

```text
1. RED: Write a replay test first:
   - Create sdk/t/replay/workflow_info.t:
     - Assert info() returns workflow_id, attempt, and task_queue carrying the values from the initializing activation.
     - Assert the already-present fields are unchanged.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:391-407: populate workflow_id, attempt, and task_queue from the activation/init data, Python-parity field names.
   - Edit Workflow.pm:470-471: correct the POD to name the fields that actually ship and drop the link to the nonexistent class.
3. REFACTOR: Source all info() fields from one init-data struct; comment cites A5 and the Python info() field list.
4. Verify: three-fields-carry-init-values; xt POD tests pass with the corrected POD; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R35: Validate Activity Options at the Call Site

**NOTE**: Finding A2. `execute_activity`/`execute_local_activity` (`Workflow/Runner.pm:449-511, :562` onward) neither require a timeout nor reject unknown options; a no-timeout call hangs in infinite retry and typos vanish silently. Part of the option-strictness story with R44 (client) and R55 (typed missing-arg): one typed class (`Temporalio::Exception::Argument`) across surfaces. Python parity for the required-timeout rule.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/activity_option_validation.t:
     - execute_activity with neither start_to_close_timeout nor schedule_to_close_timeout raises the typed argument error (assert by class).
     - execute_activity with an unknown option key raises the same class.
     - Both cases repeated for execute_local_activity.
     - A valid call with a timeout and only known keys still succeeds.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:449-511 and :562 onward: before scheduling, require at least one of start_to_close_timeout/schedule_to_close_timeout and reject unknown option keys, raising Temporalio::Exception::Argument in both cases, for both activity kinds.
3. REFACTOR: Factor a shared known-keys + required-timeout validator reused by both call sites (aligned with R44/R55); comment cites A2 and the single strictness rule.
4. Verify: no-timeout-raises, unknown-key-raises (both kinds), and valid-call-succeeds by class; full prove -lj4 t green under the memory guard.
```

### Step R44: Unify Unknown-Option Strictness on the Client Surface

**NOTE**: Finding A10. Strictness is inconsistent: `Client.pm:285-299` rejects unknowns while `Client/WorkflowHandle.pm:56` ignores them, so `result(follow_run => 0)` (a typo) silently follows continue-as-new. Same strictness rule and typed class as R35/R55.

```text
1. RED: Write a unit test first:
   - Create sdk/t/unit/client_option_strictness.t:
     - Sweep the public client methods (including WorkflowHandle::result) passing a bogus option key (e.g. the follow_run typo); assert each raises the typed argument error.
     - Assert the real/known option keys are still accepted.
2. GREEN: minimal implementation:
   - Edit Client/WorkflowHandle.pm:56 (and any other lax site) to reject unknown option keys via the same shared validator used at Client.pm:285-299, raising Temporalio::Exception::Argument.
3. REFACTOR: Extract one shared unknown-option validator used across the client surface (aligned with R35's class); comment cites A10 and the one-strictness-rule contract.
4. Verify: the typo-raises sweep passes for every swept method and known keys still pass; full prove -lj4 t green under the memory guard.
```

### Step R55: Raise Typed Errors for Missing Workflow-Context Arguments

**NOTE**: Finding A14. Missing-argument errors in workflow context are plain string dies (`Workflow/Runner.pm:451-453, :579-581`). Same validation region as R35 (`Temporalio::Exception::Argument`), so land it against the shared validator.

```text
1. RED: Write a replay test first:
   - Create sdk/t/replay/workflow_arg_errors.t:
     - Trigger the missing-argument path at Workflow/Runner.pm:451-453 and assert the failure is a Temporalio::Exception::Argument (catch and check the class, not the message).
     - Do the same at :579-581.
2. GREEN: minimal implementation:
   - Edit Workflow/Runner.pm:451-453,:579-581: replace the plain string die with Temporalio::Exception::Argument->throw (or the documented class), reusing the R35 validator where the region overlaps.
3. REFACTOR: Route both sites through the shared argument-validation helper so the typed class is uniform; comment cites A14.
4. Verify: both sites raise catchable Temporalio::Exception::Argument asserted by class; full prove -lj4 t green under the memory guard.
```

### Step R37: Wire or Reject start_workflow Extended Options

**NOTE**: Finding A7. `Client.pm:572-574` silently deletes `static_summary`, `static_details`, and `versioning_override` from start_workflow options. `static_summary`/`static_details` map through the user-metadata payloads; check Python's encoding in `../sdk-python`.

```text
1. RED: Write a request-capture test first:
   - Create sdk/t/unit/start_workflow_extended_options.t (capture the StartWorkflowExecution request without a live server):
     - start_workflow with static_summary and static_details set; assert both appear in the request's user-metadata payloads (Python encoding, cited).
     - start_workflow with versioning_override set; assert it appears on the request's versioning field.
     - For any of the three that cannot be supported, assert passing it raises the typed error instead of silent deletion.
2. GREEN: minimal implementation:
   - Edit Client.pm:572-574: stop deleting the three options; wire static_summary/static_details into the user-metadata payloads and versioning_override into its proto field. For any unsupported option, raise Temporalio::Exception::Argument rather than dropping it.
3. REFACTOR: Reuse the user-metadata encoding helper for summary/details; comment cites A7 and the Python encoding source.
4. Verify: static_summary/static_details-in-user-metadata and versioning_override-in-request (or the typed-reject for any unsupported one); full prove -lj4 t green, plus t/integration/start_workflow.t skip_all offline, under the memory guard.
```

---

## Phase P7: Test Infrastructure and Tracing

### Step R33+R46+R47+R48: DevServer and Test-Helper Future-State Fixes

**NOTE**: Findings L26 (R33), L25 (R46), T5 (R47), T6 (R48); all four live in the test helpers `Test/DevServer.pm`, `Test/Client.pm`, `Test/Worker.pm` and share the same Future 0.52 loser-state root cause documented by `verify-45/memsafe-infra/future_semantics.pl`. The DevServer shutdown test file is shared with R3 (Phase P1): coordinate so R3's timeout-path free test, R46's retry test, and R33's reaper test coexist in `sdk/t/unit/devserver_shutdown.t`.

```text
1. RED: Write unit tests first (commit an adapted verify-45/memsafe-infra/future_semantics.pl as fixture, documenting the Future 0.52 loser states in comments):
   - Create/modify sdk/t/unit/devserver_shutdown.t:
     - R33: force the start timeout with a stalled-then-later-resolving bridge future; assert the reaper shuts down the late-started CLI (observe a shutdown call, not a leaked pid).
     - R46: make the first shutdown throw; assert $is_shutdown stays false and a second shutdown call still attempts the work.
     - R47: time out the DevServer await helper; assert the surfaced diagnostic names what was awaited and the timeout, not the raw "was cancelled" message.
   - Create sdk/t/unit/test_await_helpers.t:
     - R33: force the connect timeout in Test/Client.pm with a stalled-then-resolving future; assert the late-established connection is closed.
     - R47: time out the Test/Worker.pm await helper; assert the intended diagnostic text.
     - R48: stall the first connect in connect_with_retry; assert the wedged-connect branch is reached and a retry occurs.
2. GREEN: minimal fixes:
   - Edit Test/DevServer.pm:174-187 (R33 start-timeout arm): attach a continuation that shuts down a late CLI instead of discarding it.
   - Edit Test/Client.pm:39-57 (R33 connect-timeout arm): attach a reaper that closes a late connection.
   - Edit Test/DevServer.pm:207-208 (R46): set $is_shutdown = 1 only after the shutdown work returns successfully.
   - Edit Test/DevServer.pm:35-37 and Test/Worker.pm:45-46 (R47): after wait_any, branch on the actual loser Future state (per the probe) so the timeout diagnostic path is reachable.
   - Edit Test/Client.pm:43-51 (R48): same state-correct branch so the wedged-connect retry fires.
3. REFACTOR: Factor the shared "reap the loser of a wait_any timeout race" logic into one helper if the call sites converge; comment each await helper citing L26/T5/T6 and the Future 0.52 state the branch tests for.
4. Verify: R33 reaper observed (CLI shutdown + connection close); R46 second shutdown attempts work; R47 diagnostic text at both helpers; R48 retry asserted; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R34+R61: Remove the Ephemeral-Port Race and Fix the Net::EmptyPort Dependency Phase

**NOTE**: Finding T-flake (R34, the known updates.t flake) at `Test/DevServer.pm:109,:143`, probe `verify-45/memsafe-infra/emptyport_range.pl`; and finding L29 (R61) at `Test/DevServer.pm:12` vs `sdk/cpanfile`. These close together: if R34's fix removes Net::EmptyPort, R61 collapses to deleting the dependency; else R61 moves it to the runtime phase.

```text
1. RED: Write subprocess-guarded integration tests first (commit an adapted emptyport_range.pl fixture):
   - Create sdk/t/integration/devserver_concurrent_start.t (skip_all offline, guarded via sdk/t/lib/SubprocessGuard.pm): start four dev servers concurrently in a repeated loop; assert no bind failure and no cross-connect.
   - Create sdk/t/unit/emptyport_range.t: assert the probe's claim (the picked port falls in the kernel ephemeral range); after the fix, assert startup no longer selects-then-frees a port.
   - For R61: add a dependency-audit assertion (grep use Net::EmptyPort sites vs the cpanfile phase) that fails while the phase is misclassified or the use is stale.
2. GREEN: minimal implementation:
   - Edit Test/DevServer.pm:109,:143: adopt one of the three step-45 options (pass port 0 through core and read the bound port back, hand off a bound fd, or retry-on-bind-failure with a fresh port); prefer port-0-passthrough if core exposes the bound port, else retry.
   - Edit Test/DevServer.pm:12 and sdk/cpanfile (R61): if Net::EmptyPort is now unused, drop the use and the cpanfile line; else move the declaration from the test phase to the runtime phase.
3. REFACTOR: Comment the port-selection site citing T-flake and the chosen strategy; note the R34/R61 coupling.
4. Verify: four concurrent dev servers start repeatedly with no bind failure or cross-connect; updates.t no longer flakes under prove -lj4 t; cpanfile phase matches every use site; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R49: Register Dev-Server Teardown in END Blocks

**NOTE**: Finding T9; only 3 of 33 integration files use END-block teardown (contrast `t/integration/updates.t:176-179` with the hazard documented at `Test/DevServer.pm:244-251`). The durable fix is a static xt author test; the edits sweep the offending integration files.

```text
1. RED: Write an xt author test first:
   - Create sdk/xt/devserver_end_teardown.t: statically scan every t/integration/*.t that provisions a dev server (greps a Test::DevServer construction) and assert each registers teardown in an END block; this fails now against the ~30 non-conforming files.
2. GREEN: minimal correction:
   - Edit each flagged sdk/t/integration/*.t to move or add its dev-server teardown into an END block, following the t/integration/updates.t:176-179 pattern.
3. REFACTOR: Add a one-line comment in sdk/xt/devserver_end_teardown.t citing T9 and the Test/DevServer.pm:244-251 hazard.
4. Verify: the xt probe passes across all DevServer-using integration files; a file-level die no longer orphans the CLI; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R43: Make WorkflowReplay's Nondeterminism Claim True or Scoped

**NOTE**: Finding R14 at `Test/WorkflowReplay.pm:59-95` vs `README.md:545-552`. Decision point: engage core's history comparison through the C bridge, or scope the README/POD to the Perl-side replay that actually runs. Use the temporal-docs MCP to confirm what core's replayer exposes through the bridge; if not reachable, scope. (R95 later builds the from-history replayer on top of whichever direction lands here.)

```text
1. RED: Write tests first, branching on the decision:
   - If implemented: create sdk/t/replay/nondeterminism.t driving a mutated history through the harness and asserting a typed nondeterminism error.
   - If scoped: create sdk/xt/replay_claim_scoped.t grepping README.md and Test/WorkflowReplay.pm POD for the overclaim ("nondeterminism detection through replay") and asserting it is absent; assert the shipped Perl-side check is described.
2. GREEN: minimal implementation or doc correction:
   - If reachable: edit Test/WorkflowReplay.pm:59-95 to engage the core replayer's history comparison and raise on mismatch.
   - Else: edit README.md:545-552 and the Test/WorkflowReplay.pm POD to state exactly what the Perl-side replay checks.
   - Record the direction (implement vs scope) and the temporal-docs MCP input in the commit message.
3. REFACTOR: Add a comment at Test/WorkflowReplay.pm:59 citing R14 and the chosen direction.
4. Verify: implemented -> mutated-history replay test raises the nondeterminism error; scoped -> grep probe finds no overclaim and POD maps to the shipped check; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R45: Revive the Dead Nexus Integration Test

**NOTE**: Finding T7 at `t/integration/nexus.t:74-77,:90,:103-108`: calls a nonexistent `with_worker`, passes kwargs where connect takes positionals, treats an iterator as an arrayref; the env gate hid it. Must compile (`perl -c`) offline and run green against a dev server.

```text
1. RED: Make the compile failure the RED:
   - Modify sdk/t/integration/nexus.t: add a perl -c / use-time smoke path (or run perl -c in the verify step) that currently fails because with_worker and the API misuse do not resolve; the failing compile is the reproduce-first signal.
2. GREEN: minimal correction:
   - Edit sdk/t/integration/nexus.t:74-77 to use the real worker-provisioning helper the sibling integration files use (not with_worker).
   - Edit :90 to pass positionals to connect as its signature requires.
   - Edit :103-108 to consume the iterator with its real interface instead of dereferencing it as an arrayref.
   - Ensure the file skip_alls offline exactly like its siblings.
3. REFACTOR: Align the file's structure with the nearest working integration test; comment cites T7.
4. Verify: perl -c sdk/t/integration/nexus.t passes regardless of server; prove -l t/integration/nexus.t passes with a dev server; the file skip_alls offline; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R22+R41+R42: Implement the OpenTelemetry TracingInterceptor and Point Its Tests at the Wired Behavior

**NOTE**: Findings R1 (R22, `Contrib/OpenTelemetry/TracingInterceptor.pm:205-233` pure delegation, POD at `:286-290` overclaims), T3 (R41, `t/unit/tracing.t:33-187` asserts private helpers), T4 (R42, gated subtest at `t/unit/tracing.t:201` fails with OTel installed). One unit of work. Verify span/header semantics against `../sdk-python/temporalio/contrib/opentelemetry.py`. Depends on R71 (the outbound interceptor chain) for outbound trace-context injection to have somewhere to hang. No intermediate state may ship where the POD still overclaims.

```text
1. RED: Write unit tests first (commit an adapted verify-45/api-otel/fakeotel scaffold as the fake tracer fixture under sdk/t/lib/):
   - Rewrite sdk/t/unit/tracing.t to drive the public interceptor surface, not private helpers:
     - Intercept a client call and assert a span is created on that surface.
     - Intercept a workflow-task and an activity-execution surface and assert span creation on each.
     - Assert header inject on the outbound side and extract on the inbound side round-trip the trace context.
     - Mutation check (R41): note in comments that reverting the R22 implementation to delegation-only makes these fail.
     - Fix the gated subtest (R42): construct the fixture so an OTel-installed run provides a real tracer before asserting ->tracer; assert the suite passes both with and without OpenTelemetry present.
2. GREEN: minimal implementation:
   - Edit Contrib/OpenTelemetry/TracingInterceptor.pm:205-233 to create spans for client calls, workflow tasks, and activity execution and to inject/extract trace context through headers, matching ../sdk-python/temporalio/contrib/opentelemetry.py span names and header carrier keys.
   - Edit the POD at :286-290 to describe exactly the implemented behavior.
3. REFACTOR: Extract the span-naming and header-carrier helpers; comment cites R1 and the Python contrib span/header contract; note in the closing commit that samples-perl R3 (the open-telemetry sample caveat) can now be lifted.
4. Verify: fake-tracer asserts span creation on each intercepted surface and header round-trip; reverting R22 fails the tests (R41 mutation check); the gated subtest passes with and without OTel (R42); POD matches behavior; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R70: Convert Offline-Skipping Repro Guards to Replay Tests

**NOTE**: Finding T10; all 10 integration repro guards skip offline, only 4 replay guards exist. Run LAST: depends on replay-harness capability added by the R8-R10 cluster, which makes more guards expressible as replay tests.

```text
1. RED: Write replay tests first:
   - For each convertible guard under sdk/t/integration/repro_*.t (and integration files carrying a repro guard), create a matching sdk/t/replay/<name>.t that reproduces the regression offline using the R8-R10 replay harness; each must fail if the underlying fix is reverted.
   - Mutation-check one converted guard during review (note it in the test comment).
2. GREEN: minimal conversion:
   - Move each expressible guard's assertion into its new replay test; delete or thin the offline-skipping integration guard it replaces.
   - For guards that genuinely need a live server, keep the integration form and add a comment stating why a replay test cannot express it.
3. REFACTOR: Ensure the new replay files share the existing sdk/t/replay/ harness conventions; comment cites T10.
4. Verify: the offline suite fails if any converted guard's regression is reintroduced; remaining server-only guards carry the justification comment; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

---

## Phase P8: Converter, POD, and Parity Edges

### Step R56-R59: Converter Batch (Failure-Error Wrap, utf8 Decode, Empty Payload, POD Reconcile)

**NOTE**: Findings L22 (R56, `Converter/Data.pm:152-153,:182`), L23 (R57, `Converter/Payload/JsonProtobuf.pm:48`), ADJ1 (R58, empty-data die), L24 (R59, `Converter/Payload/BinaryPlain.pm:25-27` POD vs `:53-56`; Json sibling shares the drift). R57 and R58 check `../sdk-python` converter behavior for the parity direction. R57 shares probe `verify-45/pool-payload/probe_cause_mojibake.pl` with R68. R59 is doc-only.

```text
1. RED: Write unit tests first (commit the adapted mojibake probe for R57):
   - Create sdk/t/unit/converter_errors.t:
     - R56: poison the failure converter; assert failure conversion surfaces the same typed DataConverter exception as payload conversion.
     - R57: feed malformed UTF-8 to JsonProtobuf from_payload; assert the typed conversion error (no latin-1 mojibake).
     - R58: call from_payload with empty payload data on the json and plain encodings; assert the Python-parity outcome (documented undef or the typed error), never a raw "malformed JSON string" die.
   - For R59: add/extend an sdk/xt pod assertion that each BinaryPlain and Json claim-condition POD line maps to the claiming code.
2. GREEN: minimal implementation and POD correction:
   - Edit Converter/Data.pm:152-153,:182 (R56): route failure-conversion errors through the same DataConverter error wrapping payload conversion uses.
   - Edit Converter/Payload/JsonProtobuf.pm:48 (R57): check the boolean return of utf8::decode and raise the typed error on failure.
   - Edit the empty-data path (R58) in the json and plain from_payload to the Python-parity outcome.
   - Edit Converter/Payload/BinaryPlain.pm:25-27 and the Json sibling POD (R59) to state the actual claim conditions at :53-56.
3. REFACTOR: Comments citing L22/L23/ADJ1/L24 at each site; note the R57/R68 shared probe.
4. Verify: R56 typed wrapper; R57 malformed UTF-8 raises; R58 empty-data outcome matches Python for both encodings; R59 xt pod passes and POD maps to claiming code; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R64-R66: POD Pass (list_workflows, Stale "Arrives Later", Undocumented Options)

**NOTE**: Findings A9 (R64, `Client.pm:275-281,:1109-1111`), A11 (R65, `Client.pm:1010-1011`, `Worker.pm:1060-1063`, `Activity.pm:74-79`), A12 (R66, 10 of 33 `Worker->new` kwargs undocumented; connect POD omits `interceptors`, `http_connect_proxy`, `lazy`; `rpc_metadata` sub-claim refuted, it is documented). Doc-only; xt pod coverage stays green. Survey artifact `verify-45/api-otel/worker-pod.txt`. (R66 documents `lazy` as a real option; R90 makes it work.)

```text
1. RED: the RED is failing xt/grep probes, not behavior tests:
   - Create sdk/xt/pod_arrives_later.t (R65): grep lib/ for the stale "arrives later" phrases; assert none remain (fails now).
   - Create sdk/xt/worker_connect_kwargs_documented.t (R66): enumerate accepted Worker->new and connect kwargs and cross-check against POD-documented ones; assert every accepted kwarg is documented with type and default (fails now).
   - For R64: add a small test that exercises list_workflows and asserts the actual sync/async behavior and public return contract.
2. GREEN: minimal POD correction:
   - Edit Client.pm:275-281,:1109-1111 (R64) to state the shipped sync/async behavior and the public return contract, not the private iterator class or the false async claim.
   - Edit Client.pm:1010-1011, Worker.pm:1060-1063, Activity.pm:74-79 (R65) to remove the "arrives later" text for shipped v0.2 surface.
   - Add POD entries (R66) for the undocumented Worker->new kwargs and the missing connect options (interceptors, http_connect_proxy, lazy), each with type and default.
3. REFACTOR: Keep the xt cross-check general so it catches the next undocumented option; comment cites A9/A11/A12.
4. Verify: R65 grep probe returns nothing; R66 xt cross-check passes for both surfaces; R64 return type matches the exercising test; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R54: Ship the Promised Workflow memo and search_attributes Readers

**NOTE**: Finding A6; the archived v1 spec (lines 1869-1870) promises `Workflow::memo` and `Workflow::search_attributes` readers and neither shipped. The upsert path exists; the readers are the missing half. Python-parity shapes.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/workflow_memo_sa_readers.t:
     - Read Workflow::memo and Workflow::search_attributes before an upsert and assert the initializing-activation values.
     - Upsert both, then read again and assert the readers return the updated values.
2. GREEN: minimal implementation:
   - Edit Workflow.pm (and the backing state in Workflow/Runner.pm) to add memo and search_attributes readers returning current values including upserted changes, Python-parity shapes.
3. REFACTOR: Source both readers from the same state the upsert path writes so they cannot drift; comment cites A6 and the archived spec lines.
4. Verify: both readers return initial then updated values across an upsert; xt pod covers the new readers; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R60: Align Metric-Drop Behavior with Its Documentation

**NOTE**: Finding L28 at `Runtime/MetricMeter.pm:46-52` (drops unbound records while the doc says never dropped) and `:217-218,:130` (warns unconditionally instead of rate-limited). Behavior choice: buffer-until-bound so "never dropped" is true, or document the drop window; either way the warning is rate-limited. Record the decision in the commit message.

```text
1. RED: Write a unit test first:
   - Create sdk/t/unit/metric_meter_drop.t:
     - Drive the unbound-record path and assert the documented behavior (records buffered-then-flushed on bind, or dropped per the documented window).
     - Emit many unbound records and assert the warning is rate-limited (not one warning per record).
2. GREEN: minimal implementation:
   - Edit Runtime/MetricMeter.pm:46-52 to either buffer unbound records until bound (making "never dropped" true) or keep the drop and correct the doc to state the drop window.
   - Edit :217-218,:130 to rate-limit the warning as the doc promises.
3. REFACTOR: Comment citing L28 and the chosen direction; ensure doc and code agree.
4. Verify: the unbound-record path matches the documented behavior; warn rate-limiting asserted; decision noted in the commit message; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R63: Accept the Spec-Promised Workflow Argument Forms in start_workflow

**NOTE**: Finding A8 at `Client.pm:617-625`; only the string workflow-type form is accepted, the archived v1 spec promises a definition class or ref. Check the archived spec's exact promise before implementing.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/start_workflow_argforms.t:
     - Pass a workflow definition class to start_workflow and assert the resolved workflow type name appears in the captured StartWorkflowExecution request.
     - Pass the other spec-promised form (ref) and assert the same resolution.
     - Keep the existing string form working (regression assertion).
2. GREEN: minimal implementation:
   - Edit Client.pm:617-625 to accept the definition-class and ref forms and resolve them to the workflow type name, alongside the string form.
3. REFACTOR: Reuse whatever type-name resolution the worker/definition side already exposes so resolution is single-sourced; comment cites A8 and the archived spec promise.
4. Verify: definition-class and ref forms resolve to the correct type in the request; string form unchanged; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R67: Map and Validate query reject_condition

**NOTE**: Finding A13 at `Client/WorkflowHandle.pm:379-381`; `reject_condition` is passed verbatim into the proto enum with no mapping, validation, or docs. Map named values to the proto enum, raise the typed argument error on invalid, document the names (Python-parity naming).

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/query_reject_condition.t:
     - For each named reject_condition value, assert it maps to the expected proto enum in the captured query request.
     - Pass an invalid value and assert the typed Temporalio::Exception::Argument (or documented class) is raised.
2. GREEN: minimal implementation:
   - Edit Client/WorkflowHandle.pm:379-381 to map named values to the proto enum, raise the typed argument error on an unknown value, and add POD listing the names using Python-parity naming.
3. REFACTOR: Source the name-to-enum map from one place (near the proto enum); comment cites A13.
4. Verify: each named value maps correctly; the invalid value raises the typed error; POD lists the names; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R68: Accept Non-Temporalio Causes in Exception Chaining

**NOTE**: Finding A16 at `Exception.pm:20-27`; the isa-check is too narrow and drops the chain when wrapping an arbitrary die. Accept any defined value as a cause; stringify non-exception causes into a wrapper or store as-is per the documented contract. Probe `verify-45/pool-payload/probe_cause_mojibake.pl` is shared with R57.

```text
1. RED: Write a unit test first (commit the adapted mojibake probe's cause-chaining assertions, split from the R57 UTF-8 assertions):
   - Create sdk/t/unit/exception_cause_chaining.t:
     - Chain a plain string die as a cause and assert it survives on the wrapper.
     - Chain a foreign (non-Temporalio) object as a cause and assert it survives per the documented contract.
2. GREEN: minimal implementation:
   - Edit Exception.pm:20-27 to accept any defined cause; stringify or store non-exception causes per the documented contract instead of rejecting them.
3. REFACTOR: Document the cause contract in the Exception POD; comment cites A16 and the shared probe.
4. Verify: both a string die and a foreign object survive as causes; POD states the contract; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R69: Close the Four Verified Cross-SDK Divergences

**NOTE**: Finding A17; four independent parity gaps: schedule `backfills` kwarg missing; no activity `priority`/`summary` options; page-size defaults never sent on list calls; `execute_update` overrides the caller's `wait_for_stage`. Four small INDEPENDENT diffs, one commit each. Verify each against `../sdk-python`.

```text
1. RED: Write one test per divergence first:
   - sdk/t/unit/parity_backfills.t: pass backfills to the schedule call; assert it reaches the emitted schedule request (Python parity).
   - sdk/t/unit/parity_activity_priority_summary.t: set activity priority and summary; assert both appear in the emitted command.
   - sdk/t/unit/parity_list_page_size.t: call a list method; assert the page-size default is sent on the request.
   - sdk/t/unit/parity_execute_update_wait_for_stage.t: pass an explicit wait_for_stage; assert execute_update honors it instead of overriding.
2. GREEN: four separate minimal diffs (one commit each):
   - Add the backfills kwarg to the schedule call and wire it to the proto field.
   - Add activity priority/summary options and carry them to the emitted command.
   - Send the page-size default on the list calls.
   - Stop execute_update from overriding the caller's wait_for_stage; honor the passed value.
3. REFACTOR: Each diff gets a comment citing A17 and the checked Python behavior; where a gap is closed as a documented deviation instead, state the reason per spec §0.
4. Verify: one passing assertion per item (request capture for the three wire-visible ones, behavior for wait_for_stage); each committed separately; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

---

## Phase P9: Parity — Interceptor and High-Value Gaps

R71-R82 are the high-confidence parity gaps. R71-R73 wire the outbound and nexus interceptor chains (unwired today); land R71 before or with R22 (Phase P7). The rest add concrete dropped fields verified against Python source and the vendored protos.

### Step R71: Wire and Invoke the Workflow-Outbound Interceptor Chain

**NOTE**: Parity audit, nexus/interceptor finding 1: `Worker/Interceptor.pm:57-67` defines `WorkflowOutbound` but the Runner (`Workflow/Runner.pm:1690`) builds only the inbound chain, so `execute_activity`, `start_child_workflow`, `signal_*`, and `continue_as_new` bypass interceptors and the base lacks `info()` / `start_nexus_operation()`. Python parity `worker/_interceptor.py:416-481`. Replay test. Land before or with R22: the OTel outbound span table (`Contrib/OpenTelemetry/TracingInterceptor.pm:138-150`) is unreachable until this chain exists.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/interceptor_workflow_outbound.t:
     - Register a workflow interceptor whose outbound execute_activity mutates a header/arg; drive an activation that calls execute_activity and assert the mutation reaches the emitted ScheduleActivity command.
     - Register an interceptor whose outbound start_child_workflow mutates args and assert the mutation reaches the emitted StartChildWorkflowExecution command.
     - Assert the base outbound (no interceptor) emits the un-mutated command.
     - Assert the test fails against the current unwired base.
2. GREEN: minimal implementation to Python parity:
   - Edit Worker/Interceptor.pm:57-67 to give WorkflowOutbound methods execute_activity, execute_local_activity, start_child_workflow, signal_child_workflow, signal_external_workflow, continue_as_new, start_nexus_operation, info, each delegating to next by default.
   - Edit Workflow/Runner.pm:1690 to construct a root workflow-outbound interceptor, fold the configured interceptor list over it, call inbound->init(outbound), and route the eight outbound operations through the chain; verify method set and folding order against ../sdk-python/temporalio/worker/_interceptor.py:416-481.
3. REFACTOR: Extract the outbound-chain construction into a single helper alongside the existing inbound folding; comment cites parity finding 1 and _interceptor.py:416-481.
4. Verify: outbound execute_activity/start_child_workflow mutation reaches the emitted command; fails on unwired base; full prove -lj4 t green under the memory guard.
```

### Step R72: Add the Activity-Outbound Interceptor and Wire ActivityInbound.init

**NOTE**: Parity audit, nexus/interceptor finding 2: no `Temporalio::Worker::ActivityOutbound` exists and `Worker/ActivityDispatcher.pm:152` builds the inbound chain but never calls `$inbound->init($outbound)`, so `activity.info()` / `activity.heartbeat()` bypass any custom interceptor. Python parity `worker/_interceptor.py:135-156`. Unit test.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/interceptor_activity_outbound.t:
     - Register an activity interceptor overriding outbound heartbeat; run an activity body that calls heartbeat and assert the override fires before/instead of reaching Activity/Context.
     - Register an interceptor overriding outbound info and assert it observes the info call.
     - Assert the base (no interceptor) still heartbeats through to the context.
2. GREEN: minimal implementation to Python parity:
   - Add Temporalio::Worker::ActivityOutbound with info and heartbeat delegating to next by default (in Worker/Interceptor.pm).
   - Edit Worker/ActivityDispatcher.pm:152 to build a root activity-outbound, fold the interceptor list over it, and call inbound->init(outbound).
   - Route Activity/Context.pm heartbeat and info through the outbound chain; verify against ../sdk-python/temporalio/worker/_interceptor.py:135-156.
3. REFACTOR: Share the fold-over-root helper with R71 where practical; comment cites parity finding 2 and _interceptor.py:135-156.
4. Verify: activity interceptor override of outbound heartbeat fires when the body calls heartbeat; full prove -lj4 t green under the memory guard.
```

### Step R73: Add the Nexus Operation Inbound Interceptor Role

**NOTE**: Parity audit, nexus/interceptor finding 3: `Worker/Interceptor.pm:73-76` defines only `intercept_activity` / `intercept_workflow`; there is no `intercept_nexus_operation` or `NexusOperationInbound`, and `NexusDispatcher::_handle_start` (`Worker/NexusDispatcher.pm:196`) and `_handle_cancel_operation` (`:257`) invoke the handler directly with no chain. Python parity `worker/_interceptor.py:66-78, 500-528`. Unit test.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/interceptor_nexus_inbound.t:
     - Dispatch a nexus start task with an interceptor overriding execute_nexus_operation_start; assert the override runs before the handler body.
     - Dispatch a cancel task with an interceptor overriding execute_nexus_operation_cancel and assert it wraps the handler call.
     - Assert the base (no interceptor) runs the handler directly with the same result.
2. GREEN: minimal implementation to Python parity:
   - Add intercept_nexus_operation to Temporalio::Worker::Interceptor (Worker/Interceptor.pm:73-76) and a NexusOperationInbound base with execute_nexus_operation_start and execute_nexus_operation_cancel.
   - Edit Worker/NexusDispatcher.pm:196 (_handle_start) and :257 (_handle_cancel_operation) to fold the interceptor list over a root that runs the handler and dispatch through the chain; verify against ../sdk-python/temporalio/worker/_interceptor.py:66-78,500-528.
3. REFACTOR: Unify the nexus fold with the R71/R72 chain helper; comment cites parity finding 3 and _interceptor.py:66-78,500-528.
4. Verify: nexus-start interceptor override runs before the handler body; full prove -lj4 t green under the memory guard.
```

### Step R74: Carry ApplicationError next_retry_delay Through Exception and Failure Proto

**NOTE**: Parity audit, activity/conversion finding 1: `Exception/Application.pm:11-14` has no `next_retry_delay` field and `Converter/Failure.pm:231-240,:251-261` never reads/writes `ApplicationFailureInfo.next_retry_delay`, though the proto field exists (`share/proto/temporal/api/failure/v1/message.proto:27`). Python parity `exceptions.py:133,168-175` and `converter/_failure_converter.py:160-162,340`. Distinct from R5 (fork-channel fields only).

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/application_error_next_retry_delay.t:
     - Build an ApplicationError with next_retry_delay, run to_failure then from_failure, assert the value survives the round-trip.
     - Assert the on-wire Failure's ApplicationFailureInfo.next_retry_delay proto field is set (as a Duration) to the passed value.
     - Assert an ApplicationError without next_retry_delay leaves the proto field unset.
2. GREEN: minimal implementation to Python parity:
   - Edit Exception/Application.pm:11-14 to accept and store next_retry_delay.
   - Edit Converter/Failure.pm:231-240 (write) and :251-261 (read) to map next_retry_delay to/from ApplicationFailureInfo.next_retry_delay (Duration), matching ../sdk-python/temporalio/converter/_failure_converter.py:160-162,340.
3. REFACTOR: Centralize the Duration<->seconds conversion if duplicated; comment cites parity finding 1 and the proto field message.proto:27.
4. Verify: value survives to_failure/from_failure and appears in the proto field; full prove -lj4 t green under the memory guard.
```

### Step R75: Support encode_common_attributes on the Failure Converter

**NOTE**: Parity audit, activity/conversion finding 2: `Converter/Failure.pm` always writes cleartext `message`/`stack_trace` and never produces or reads `encoded_attributes`, so a configured codec cannot protect the failure message/stack trace and no `DefaultFailureConverterWithEncodedAttributes` equivalent is constructible. Python parity `converter/_failure_converter.py:84,119-127,312-327,461-468`. R7 extends the codec surface but assumes the payloads exist; R56 only wraps conversion errors.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/failure_encode_common_attributes.t:
     - With encode_common_attributes on and a marker codec, run to_failure and assert the on-wire Failure has message "Encoded failure", empty stack_trace, and a codec-tagged encoded_attributes payload.
     - Run from_failure on that Failure and assert the original message and stack_trace are recovered.
     - With encode_common_attributes off, assert message/stack_trace stay cleartext and encoded_attributes is absent.
2. GREEN: minimal implementation to Python parity:
   - Edit Converter/Failure.pm to accept encode_common_attributes; when set, to_failure relocates message and stack_trace into an encoded_attributes payload (message -> "Encoded failure", stack_trace -> ""), and from_failure restores them, matching ../sdk-python/temporalio/converter/_failure_converter.py:84,119-127,312-327,461-468.
   - Confirm Converter/Data.pm:99-102 codec-transforms the encoded_attributes payload once produced.
3. REFACTOR: Name the "Encoded failure" sentinel as a constant; comment cites parity finding 2 and _failure_converter.py:312-327.
4. Verify: on-wire message "Encoded failure" + codec-tagged encoded_attributes; from_failure recovers original message and stack trace; full prove -lj4 t green under the memory guard.
```

### Step R76: Expose Activity Cancellation Details and Reason

**NOTE**: Parity audit, worker finding 2 + activity/conversion finding 3: `Worker/ActivityDispatcher.pm:105-113` receives the `Cancel` job (carrying `reason` and an `ActivityCancellationDetails`, proto `activity_task.proto`) but fires only `->cancel` and discards both, and `Activity/Context.pm` exposes one cancellation future whose POD conflates server-cancel with worker-shutdown. Python parity `activity.py:169-191,315-317` and `worker/_activity.py:221-226`. Distinct from R18/R19.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/activity_cancellation_details.t:
     - Deliver a Cancel carrying WORKER_SHUTDOWN and assert the context's cancellation_details reports the matching reason and boolean flags.
     - Deliver a Cancel carrying PAUSED and assert the context reports paused.
     - Assert an un-cancelled context reports no cancellation_details.
2. GREEN: minimal implementation to Python parity:
   - Edit Worker/ActivityDispatcher.pm:105-113 to capture the Cancel job's reason and ActivityCancellationDetails instead of discarding them.
   - Add a cancellation_details accessor on Activity/Context.pm exposing the boolean fields (cancel_requested, not_found, paused, timed_out, worker_shutdown, reset), matching ../sdk-python/temporalio/activity.py:169-191,315-317.
3. REFACTOR: Fix the Context POD to stop conflating server-cancel with worker-shutdown; comment cites worker finding 2 / activity finding 3 and worker/_activity.py:221-226.
4. Verify: WORKER_SHUTDOWN and PAUSED cancels each report the matching reason and details; full prove -lj4 t green (and prove -lj4 xt for the POD change) under the memory guard.
```

### Step R77: Add workflow.uuid4 Deterministic UUID

**NOTE**: Parity audit, in-workflow finding 1: `Workflow.pm:72` exposes `random` but no `uuid4`; the only UUID code is client-side `Temporalio::Client::_new_uuid`, which is non-deterministic and not workflow-safe. Python parity `workflow/_context.py:866`.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/workflow_uuid4.t:
     - Assert uuid4() returns a syntactically valid v4 UUID (version nibble 4, variant bits) and is stable across replay of the same run.
     - Assert a second uuid4() call in the same run differs from the first.
     - Assert the value is derived from the activation randomness seed (same seed -> same sequence).
2. GREEN: minimal implementation to Python parity:
   - Add Temporalio::Workflow::uuid4 to Workflow.pm returning a v4 UUID drawn from the workflow's deterministic RNG (the same seed source as random at :72), matching ../sdk-python/temporalio/workflow/_context.py:866.
3. REFACTOR: Reuse the existing deterministic RNG rather than a fresh generator; comment cites in-workflow finding 1 and _context.py:866.
4. Verify: stable across replay, differs from a second call, seeded from the activation randomness seed; full prove -lj4 t green (and prove -lj4 xt for the new POD) under the memory guard.
```

### Step R78: Carry a Summary on Timers, sleep, and wait_condition Timeouts

**NOTE**: Parity audit, in-workflow finding 2: `Workflow::sleep`/`start_timer` take only `$seconds` (`Workflow.pm:241,250`), `Runner::start_timer` (`Runner.pm:1220`) emits StartTimer with no user-metadata, and `wait_condition` (`Runner.pm:1366,1388`) passes no summary. Python parity `workflow/_context.py:878,894`. R69 covers activity summary only.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/timer_summary.t:
     - Call sleep with a summary and assert the emitted StartTimer command carries the user-metadata single-line summary payload.
     - Call start_timer with a summary and assert the same.
     - Call wait_condition with a timeout_summary and assert its backing timer carries the summary.
     - Call sleep/start_timer with no summary and assert StartTimer carries no user-metadata.
2. GREEN: minimal implementation to Python parity:
   - Edit Workflow.pm:241,250 so sleep/start_timer accept a summary, and add timeout_summary to wait_condition.
   - Edit Workflow/Runner.pm:1220 (start_timer) to set StartTimer user-metadata summary, and :1366,:1388 (wait_condition) to thread timeout_summary through, matching ../sdk-python/temporalio/workflow/_context.py:878,894.
3. REFACTOR: Reuse the local-activity user-metadata summary builder rather than duplicating it; comment cites in-workflow finding 2 and _context.py:878,894.
4. Verify: StartTimer carries the user-metadata summary when passed, none when omitted; full prove -lj4 t green under the memory guard.
```

### Step R79: Expose Per-Activation Workflow Info Accessors

**NOTE**: Parity audit, in-workflow finding 3: no accessors exist for the current activation's `history_length`, `history_size_bytes`, `build_id`, or `continue_as_new_suggested`; R36 completes only the static `info()` fields, while these four are per-activation dynamic values the Runner receives but never surfaces. Python parity `workflow/_context.py:140,165,175,185`.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/workflow_activation_info.t:
     - Drive an activation carrying history_length, history_size_bytes, build_id, and continue_as_new_suggested and assert get_current_history_length, get_current_history_size, get_current_build_id, and is_continue_as_new_suggested each return the delivered value.
     - Drive a second activation with changed values and assert each accessor reflects the update.
2. GREEN: minimal implementation to Python parity:
   - Edit Workflow/Runner.pm to capture the four per-activation fields each activation and expose get_current_history_length, get_current_history_size, get_current_build_id, is_continue_as_new_suggested (or equivalent info accessors), matching ../sdk-python/temporalio/workflow/_context.py:140,165,175,185.
3. REFACTOR: Store the four fields in one per-activation struct updated at the activation boundary; comment cites in-workflow finding 3 and _context.py:140-185.
4. Verify: each accessor returns the delivered value, per-activation; full prove -lj4 t green (and prove -lj4 xt for new POD) under the memory guard.
```

### Step R80: Add the max_concurrent_nexus_tasks Worker Kwarg

**NOTE**: Parity audit, worker finding 1: the fallback fixed tuner hardcodes `nexus_task_slots => 100` (`Worker.pm:300,416`), no `max_concurrent_nexus_tasks` field exists (`Worker.pm:60-62`), and it is absent from the tuner mutual-exclusion set (`Worker.pm:959-961`). Python parity `worker/_worker.py:31,129-133`.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/worker_max_concurrent_nexus_tasks.t:
     - Build a Worker with max_concurrent_nexus_tasks => N and assert the synthesized fixed tuner packs a FixedSize nexus slot supplier of N.
     - Assert an unset kwarg keeps the 100 default.
     - Assert passing max_concurrent_nexus_tasks alongside tuner throws the mutual-exclusion error.
2. GREEN: minimal implementation to Python parity:
   - Edit Worker.pm:60-62 to accept max_concurrent_nexus_tasks, :300/:416 to feed it into the synthesized fixed tuner's nexus slot supplier (default 100), and :959-961 to add it to the tuner mutual-exclusion set; verify against ../sdk-python/temporalio/worker/_worker.py:31,129-133.
   - Confirm Worker/Tuner.pm's FixedSize supplier accepts the N.
3. REFACTOR: Fold the nexus kwarg into the existing max_concurrent_{activities,workflow_tasks,local_activities} handling; comment cites worker finding 1 and _worker.py:129-133.
4. Verify: FixedSize nexus supplier of N packed into the tuner; mutual-exclusion error alongside tuner; full prove -lj4 t green under the memory guard.
```

### Step R81: Add fairness_key and fairness_weight to Priority

**NOTE**: Parity audit, schedule/runtime finding 3: `Common/Priority.pm` declares and encodes only `priority_key`, though the vendored proto (`share/proto/temporal/api/common/v1/message.proto:344,354`) already carries `fairness_key` and `fairness_weight`. Python parity `common.py:1149-1220`.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/priority_fairness.t:
     - Construct a Priority with priority_key, fairness_key, and fairness_weight and assert to_proto sets all three on temporal.api.common.v1.Priority.
     - Assert a Priority with only priority_key leaves fairness_key/fairness_weight unset.
2. GREEN: minimal implementation to Python parity:
   - Edit Common/Priority.pm to accept fairness_key (string) and fairness_weight (float) and encode both into Priority.fairness_key and Priority.fairness_weight, matching ../sdk-python/temporalio/common.py:1149-1220.
3. REFACTOR: Validate fairness_weight type at construction as Python does; comment cites schedule/runtime finding 3 and message.proto:344,354.
4. Verify: to_proto sets priority_key, fairness_key, and fairness_weight; full prove -lj4 t green under the memory guard.
```

### Step R82: Encode static_summary and static_details on the Schedule Action

**NOTE**: Parity audit, schedule/runtime finding 1: `Schedule/Action.pm:28-39` declares no `static_summary`/`static_details` and `_to_proto` (`:73-124`) never sets `user_metadata`; a separate code path from direct `start_workflow` (R37) and the schedule backfills kwarg (R69). Python parity `client/_schedule.py:551-552`.

```text
1. RED: Write request-capture tests first:
   - Create sdk/t/integration/schedule_action_user_metadata.t (subprocess-guarded via sdk/t/lib/SubprocessGuard.pm; skip_all offline) or a request-capture replay test:
     - Create a schedule whose StartWorkflow action carries static_summary and static_details and assert both appear as encoded payloads in the emitted NewWorkflowExecutionInfo.user_metadata (summary and details).
     - Assert an action without them emits no user_metadata.
2. GREEN: minimal implementation to Python parity:
   - Edit Schedule/Action.pm:28-39 so StartWorkflow accepts static_summary and static_details, and :73-124 (_to_proto) to encode them into NewWorkflowExecutionInfo.user_metadata (summary + details payloads), matching ../sdk-python/temporalio/client/_schedule.py:551-552.
3. REFACTOR: Reuse the R37 user-metadata payload builder rather than duplicating it; comment cites schedule/runtime finding 1 and _schedule.py:551-552.
4. Verify: static_summary and static_details appear as encoded payloads in the emitted user_metadata; full prove -lj4 t green under the memory guard.
```

---

## Phase P10: Parity — Medium and Low

The judgment calls are resolved: R95 implements the from-history replayer, R96 exposes a context-detail accessor (no mandated logging framework), R97 is doc-only (document the deliberate deviation, do not port the deprecated APIs).

### Step R83: Expose a User-Facing Metric Meter in Workflow, Activity, and Nexus Context

**NOTE**: Parity audit (in-workflow finding 6, schedule/runtime finding 2, nexus finding 4): user code cannot emit counters/histograms/gauges; `Runtime/MetricMeter.pm` is only the custom-sink consumer. Python parity `activity.py:247,461`, `workflow/_context.py:710`, `nexus/_operation_context.py:107`. Distinct from R60 (custom-sink drop).

```text
1. RED: Write replay + unit tests first:
   - Create sdk/t/replay/metric_meter_workflow.t:
     - A workflow records a counter via Temporalio::Workflow->metric_meter->create_counter(...)->add(1, {attr}) and asserts the value reaches a captured test buffer/exporter when the activation is live.
     - The same counter add is suppressed (no emit) while the activation replays.
   - Create sdk/t/unit/metric_meter_activity.t:
     - An activity records a counter via $ctx->metric_meter->create_counter(...)->add(1) and asserts it reaches the test buffer.
     - A nexus operation context exposes metric_meter yielding a usable counter (edge: per-call attributes merge).
2. GREEN: minimal implementation to Python parity:
   - Edit Runtime/MetricMeter.pm: add the emission surface (create_counter/create_histogram/create_gauge returning instrument objects with add/record/set accepting per-call attributes) backed by the core meter, mirroring Python's MetricMeter.
   - Edit Activity/Context.pm: expose metric_meter (activity.py:247,461).
   - Edit Workflow.pm: expose metric_meter that no-ops instrument emits during replay (workflow/_context.py:710); read the replay flag from Workflow/Runner.pm.
   - Edit Nexus/OperationContext.pm: expose metric_meter (nexus/_operation_context.py:107).
   - Verify each surface against ../sdk-python at implementation time.
3. REFACTOR: Factor the instrument-construction path so workflow/activity/nexus share one meter wrapper; comment cites parity finding 6 and the replay-suppression contract.
4. Verify: replay counter emits live and is suppressed on replay; activity counter reaches buffer; nexus meter usable; full prove -lj4 t green under the memory guard.
```

### Step R84: Provide Worker-Shutdown Detection Inside Activities

**NOTE**: Parity audit (activity/conversion finding 4): `Activity/Context.pm:28-30` folds worker shutdown into the single cancellation token, so an activity cannot distinguish graceful shutdown from a plain cancel. Python parity `activity.py:400-438`.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/activity_worker_shutdown.t:
     - With an activity awaiting the shutdown future, triggering worker shutdown makes $ctx->is_worker_shutdown return true and resolves $ctx->worker_shutdown_future (or wait_for_worker_shutdown).
     - Edge: an ordinary cancel that is NOT a worker shutdown leaves is_worker_shutdown false, so the two events are distinguishable.
2. GREEN: minimal implementation to Python parity:
   - Edit Activity/Context.pm:28-30: add a distinct worker-shutdown event/future separate from the cancellation token; expose is_worker_shutdown and an awaitable shutdown future fired when the worker begins shutdown (activity.py:400-438).
   - Fire the shutdown event from the worker/activity dispatcher at shutdown-begin, before cancel propagation.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Name the shutdown event/future consistently with Python; comment cites finding 4 and the shutdown-vs-cancel distinction.
4. Verify: shutdown flips is_worker_shutdown and resolves the future; plain cancel does not; full prove -lj4 t green under the memory guard.
```

### Step R85: Complete Activity Info with priority and retry_policy

**NOTE**: Parity audit (activity/conversion finding 5): `Worker/ActivityDispatcher.pm:320-341` omits `priority` and `retry_policy`, both present on `ActivityTask.Start`. Python parity `activity.py:130-136`. R36 completes workflow info(), not activity Info.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/activity_info_priority_retry.t:
     - Dispatching a start job carrying a retry_policy (initial interval, backoff, max attempts) surfaces $info->retry_policy with those fields on the activity Info.
     - A start job carrying priority (priority key / fairness fields) surfaces $info->priority.
     - Edge: a start job with neither yields undef/empty for both without error.
2. GREEN: minimal implementation to Python parity:
   - Edit Worker/ActivityDispatcher.pm:320-341: populate priority and retry_policy on the built Info from the start job, using Python field naming (activity.py:130-136).
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Reuse the existing priority/retry-policy proto-to-object mappers if present; comment cites finding 5.
4. Verify: both fields surface from a populated start job and stay absent when omitted; full prove -lj4 t green under the memory guard.
```

### Step R86: Support Runtime Signal, Query, and Update Handler Registration

**NOTE**: Parity audit (in-workflow finding 4): handlers bind only at definition time via attributes; no runtime `set_*_handler`/`get_*_handler`. Python parity `workflow/_workflow_ops.py:833-985`.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/runtime_handler_registration.t:
     - Install a signal handler via Temporalio::Workflow->set_signal_handler($name, $code) after start, deliver a signal for that name, and assert the new handler runs.
     - A signal that arrived BEFORE registration (buffered) drains and runs on registration, matching Python buffered-signal replay semantics.
     - Edge: get_signal_handler/get_query_handler/get_update_handler return the installed coderef, and setting to undef removes it.
2. GREEN: minimal implementation to Python parity:
   - Edit Workflow.pm and Workflow/Runner.pm: add runtime setters/getters that install or replace named and dynamic signal, query, and update handlers on the running instance; drain buffered signals for a name on registration (_workflow_ops.py:833-985).
   - Edit Workflow/Definition.pm if the handler registry needs a mutable runtime layer over the compile-time table.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Unify the compile-time attribute registry and the runtime table behind one lookup path; comment cites finding 4 and the buffered-drain contract.
4. Verify: runtime-set signal handler runs; buffered pre-registration signal drains; getters return installed handlers; full prove -lj4 t green under the memory guard.
```

### Step R87: Honor Per-Handler HandlerUnfinishedPolicy

**NOTE**: Parity audit (in-workflow finding 5): `Workflow/Attributes.pm` parses only `name`/`dynamic`; no `unfinished_policy`, and `Workflow.pm:418-421` warns on abandon unconditionally. Python parity `workflow/_handlers.py:36`.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/handler_unfinished_policy.t:
     - Completing a workflow with an in-flight update handler declared :Update(unfinished_policy => 'ABANDON') produces NO unfinished-handler warning.
     - The default (no policy) still warns when a handler is in-flight at completion.
     - Edge: a :Signal handler honors the same policy option.
2. GREEN: minimal implementation to Python parity:
   - Edit Workflow/Attributes.pm: parse an unfinished_policy option on :Signal and :Update (default WARN_AND_ABANDON, opt-out ABANDON), matching _handlers.py:36.
   - Edit Workflow.pm:418-421: consult the per-handler policy so ABANDON suppresses the completion warning; default still warns.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Thread the policy through the handler descriptor rather than a side table; comment cites finding 5 and Python's default-warn/opt-out-abandon.
4. Verify: ABANDON handler completes with no warning; default warns; signal honors policy; full prove -lj4 t green under the memory guard.
```

### Step R88: Expose Last-Completion-Result and Last-Failure

**NOTE**: Parity audit (in-workflow finding 7): no accessors for the InitializeWorkflow `last_completion_result`/`last_failure`, so a cron/scheduled workflow cannot read the previous run's result or failure. Python parity `workflow/_context.py:675,688,696`.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/last_completion_result.t:
     - Seed an InitializeWorkflow with a last_completion_result payload and assert Temporalio::Workflow->has_last_completion_result is true and get_last_completion_result returns the decoded value (with the documented type-hint behavior).
     - Seed a last_failure and assert get_last_failure returns the typed failure object.
     - Edge: with neither field set, has_last_completion_result is false and get_last_failure returns undef.
2. GREEN: minimal implementation to Python parity:
   - Edit Workflow/Runner.pm: capture the carry-over fields off the initializing activation and surface has_last_completion_result, get_last_completion_result, get_last_failure with documented decode/type-hint behavior (_context.py:675,688,696).
   - Expose the accessors on Workflow.pm.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Decode lazily on first access; comment cites finding 7.
4. Verify: seeded result decodes, seeded failure types correctly, absent fields report false/undef; full prove -lj4 t green under the memory guard.
```

### Step R89: Restore Dropped Nexus Handler-Context Capabilities

**NOTE**: Parity audit (nexus finding 4): `Nexus.pm:40-54` omits `wait_for_worker_shutdown`/`_sync`, `is_worker_shutdown` reads a `$IS_WORKER_SHUTDOWN` (`Nexus.pm:29,54`) no dispatcher sets, and `OperationInfo` (`Nexus/OperationContext.pm:18-28`) omits `namespace`. Metric meter is R83. Python parity `nexus/_operation_context.py:82-147`.

```text
1. RED: Write unit tests first:
   - Create sdk/t/unit/nexus_context_capabilities.t:
     - Inside a dispatched nexus operation OperationInfo->namespace matches the worker namespace.
     - is_worker_shutdown is false before shutdown and flips true once the dispatcher enters shutdown drain; wait_for_worker_shutdown/_sync resolve then.
2. GREEN: minimal implementation to Python parity:
   - Edit Nexus/OperationContext.pm:18-28: add namespace to OperationInfo (_operation_context.py:82-147).
   - Edit Nexus.pm:40-54: add wait_for_worker_shutdown and its sync variant; set $IS_WORKER_SHUTDOWN (Nexus.pm:29,54) from the dispatcher drain so is_worker_shutdown reflects reality.
   - Wire the nexus dispatcher to flip the flag on shutdown-begin.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Share the shutdown-flip mechanism with the activity shutdown event (R84) if it lands nearby; comment cites nexus finding 4.
4. Verify: namespace matches, is_worker_shutdown flips on drain, waiters resolve; full prove -lj4 t green under the memory guard.
```

### Step R90: Implement Lazy Client Connections

**NOTE**: Parity audit (client finding 3): `Client.pm:817,829-831` accepts `lazy` then throws "not supported in v0.1"; R66 only documents `lazy`, presuming it works. Python parity `client/_client.py:151,205-207`.

```text
1. RED: Write subprocess-guarded integration tests first:
   - Create sdk/t/integration/lazy_client.t (guarded via sdk/t/lib/SubprocessGuard.pm):
     - Temporalio::Client->connect(lazy => 1, target => <unreachable>) returns a client object WITHOUT error (no connect attempt yet).
     - The gRPC connection is attempted only on the first RPC (the failure/connect surfaces on first call, not at construct).
     - Edge: lazy => 0/absent keeps the eager path (connect attempted at construct).
2. GREEN: minimal implementation to Python parity:
   - Edit Client.pm:817,829-831: remove the stale "not supported" throw; when lazy is set, defer the core client connection until the first RPC (_client.py:151,205-207); eager path unchanged otherwise.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Guard the deferred-connect with a single once-init so concurrent first RPCs share one connect; comment cites finding 3 and removes the stale v0.1 message.
4. Verify: lazy construct against unreachable target succeeds; connect happens on first RPC; eager path unchanged; full prove -lj4 t green under the memory guard.
```

### Step R91: Expose Raw Service Clients on the Client

**NOTE**: Parity audit (client finding 1): no raw RPC passthrough; `Client/Connection.pm` holds only the core client pointer, so operator-service RPCs (add/remove search attributes, describe cluster) are unreachable. Python parity `client/_client.py:307-322`.

```text
1. RED: Write subprocess-guarded integration tests first:
   - Create sdk/t/integration/raw_service_client.t (guarded via sdk/t/lib/SubprocessGuard.pm, skip_all offline):
     - Issue an OperatorService RPC (e.g. add/remove search attributes) through the raw handle and assert the request is formed and sent (request-captured), matching Python's operator_service passthrough.
     - A WorkflowService raw RPC round-trips through the handle.
2. GREEN: minimal implementation to Python parity:
   - Edit Client/Connection.pm: expose a low-level service handle over the WorkflowService and OperatorService RPC surface (at minimum operator search-attribute management) driving the core client pointer (_client.py:307-322).
   - Edit Client.pm: add workflow_service/operator_service accessors returning the handle.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Generate the RPC method map from the proto service descriptors rather than hand-listing; comment cites finding 1.
4. Verify: operator-service RPC forms/sends; workflow-service raw RPC round-trips; full prove -lj4 t green under the memory guard.
```

### Step R92: Add WorkflowHandle get_update_handle

**NOTE**: Parity audit (client finding 2): `Client/WorkflowHandle.pm` has no `get_update_handle`; the backing `Client/WorkflowUpdateHandle.pm:41-79` already polls purely from id/run/update-id with a public constructor. Python parity `client/_workflow.py:978,1008`.

```text
1. RED: Write subprocess-guarded integration tests first:
   - Create sdk/t/integration/get_update_handle.t (guarded via sdk/t/lib/SubprocessGuard.pm):
     - $handle->get_update_handle($update_id, run_id => $r, result_type => $t) returns a WorkflowUpdateHandle and its result polls PollWorkflowExecutionUpdate with the given update id and the handle's run id (request-captured).
     - Edge: omitting run_id binds the update handle to the handle's own run id.
2. GREEN: minimal implementation to Python parity:
   - Edit Client/WorkflowHandle.pm: add get_update_handle(update_id, run_id => ..., result_type => ...) returning a WorkflowUpdateHandle bound to the handle's run via the existing public constructor (_workflow.py:978,1008).
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Default run_id/workflow id from the handle in one place; comment cites finding 2.
4. Verify: built handle polls PollWorkflowExecutionUpdate with the correct update and run id; full prove -lj4 t green under the memory guard.
```

### Step R93: Honor a Client-Level Default Query Reject Condition

**NOTE**: Parity audit (client finding 4): `Client.pm:800-824` connect neither accepts nor stores `default_workflow_query_reject_condition`, and `Client/WorkflowHandle.pm:379-380` reads only a per-call `reject_condition`; R67 covers only per-call enum mapping. Python parity `client/_client.py:144-145,184-187`.

```text
1. RED: Write subprocess-guarded integration tests first:
   - Create sdk/t/integration/default_query_reject_condition.t (guarded via sdk/t/lib/SubprocessGuard.pm):
     - connect(default_workflow_query_reject_condition => NOT_OPEN) then query without a per-call condition emits an outbound QueryWorkflow carrying the client default (request-captured).
     - A per-call reject_condition overrides the client default.
     - Edge: no default and no per-call value leaves the condition unset.
2. GREEN: minimal implementation to Python parity:
   - Edit Client.pm:800-824: accept and store default_workflow_query_reject_condition on connect (_client.py:144-145,184-187).
   - Edit Client/WorkflowHandle.pm:379-380: apply the stored default when query omits reject_condition; per-call value wins.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Resolve the effective condition in one helper shared by all query paths; comment cites finding 4.
4. Verify: default rides the outbound query; per-call overrides; neither leaves it unset; full prove -lj4 t green under the memory guard.
```

### Step R94: Add an on_fatal_error Worker Hook

**NOTE**: Parity audit (worker finding 3): `Worker.pm` has no `on_fatal_error`; `run()` re-raises loop failures (`Worker.pm:568,589`) with no callback before the shutdown sequence. Python parity `worker/_worker.py:47,202-204`.

```text
1. RED: Write subprocess-guarded integration tests first:
   - Create sdk/t/integration/worker_on_fatal_error.t (guarded via sdk/t/lib/SubprocessGuard.pm):
     - A worker whose poll loop dies fatally invokes the on_fatal_error coderef with the error before run() returns.
     - A throwing on_fatal_error hook is logged/ignored and does NOT mask the original fatal failure (original error still propagates from run()).
2. GREEN: minimal implementation to Python parity:
   - Edit Worker.pm: add an on_fatal_error field to Worker->new; invoke it with the error before the fatal-path shutdown at Worker.pm:568,589; catch and log-then-ignore exceptions from the hook (_worker.py:47,202-204).
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Route the hook invocation through the single fatal-path unwind point; comment cites finding 3.
4. Verify: hook fires with the error before run() returns; a throwing hook is swallowed and the original failure still surfaces; full prove -lj4 t green under the memory guard.
```

### Step R95: Provide a Real-History and Multi-History Replayer Surface

**NOTE**: Parity audit (worker finding 4): `Test/WorkflowReplay.pm` is an activation-pushing harness keyed to one `workflow_class` (`:14`) with no history-JSON input, no batch replay, no aggregated result; R43 covers only its nondeterminism truthfulness. Resolved direction: IMPLEMENT the from-history + batch replayer. Python parity `worker/_replayer.py:110,138,166`.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/history_replayer.t:
     - Replaying a downloaded multi-event WorkflowHistory JSON returns one result per history.
     - A mutated history yields a Nondeterminism failure in that history's result while a valid one passes.
     - WorkflowHistory->from_json reconstructs a history that replays identically to the fetched form.
2. GREEN: minimal implementation to Python parity:
   - Edit Test/WorkflowReplay.pm: accept real WorkflowHistory objects (fetched or JSON-loaded), add from_json construction, and replay a stream of histories returning a per-history result; surface nondeterminism as a per-history failure (_replayer.py:110,138,166).
   - Add/complete the WorkflowHistory type with from_json if absent.
   - Verify against ../sdk-python at implementation time.
3. REFACTOR: Reuse the R43 real nondeterminism check inside the per-history loop; comment cites finding 4 and the resolved from-history direction.
4. Verify: batch returns per-history results; mutated history fails with Nondeterminism; from_json round-trips identically; full prove -lj4 t green under the memory guard.
```

### Step R96: Add an Activity Context-Aware Logger

**NOTE**: Parity audit (activity/conversion finding 6): no activity logger surface; Python embeds activity id, type, attempt, namespace, task queue, and workflow ids into every log line. Resolved direction: expose a context-detail accessor plus a documented pattern (do NOT mandate a logging framework). Python parity `activity.py:479-537`.

```text
1. RED: Write unit + xt author tests first:
   - Create sdk/t/unit/activity_log_details.t:
     - $ctx->log_details (or equivalent) yields the documented field set for the running activity: activity id, activity type, attempt, namespace, task queue, and the workflow id / run id.
     - Edge: the accessor is populated inside a dispatched activity and reflects the current attempt.
   - Extend sdk/xt/ POD coverage to require the documented logger-wiring pattern is present in Activity/Context.pm POD (RED: fails until the note exists).
2. GREEN: minimal implementation to the resolved direction:
   - Edit Activity/Context.pm: expose the logging-detail accessor with the full field set (activity.py:479-537); do not add a logging dependency.
   - Add POD documenting the pattern for attaching the details to the caller's logger (for example Log::Any).
   - Verify the field set against ../sdk-python at implementation time.
3. REFACTOR: Build the detail hash once from the existing Info rather than re-deriving; comment cites finding 6 and the "no mandated framework" resolution.
4. Verify: accessor yields the documented fields for the running activity; POD documents the wiring pattern; full prove -lj4 t and prove -lj4 xt green under the memory guard.
```

### Step R97: Document the Legacy Build-ID Worker-Versioning APIs as a Deliberate Deviation

**NOTE**: Parity audit (client finding 5): the three legacy build-id client RPCs (`update_worker_build_id_compatibility`, `get_worker_build_id_compatibility`, `get_worker_task_reachability`) are absent; all three are deprecated in Python (`client/_client.py:2770,2801,2832`) and superseded by deployment versioning Perl already implements. Resolved decision: DOC-ONLY, do NOT port them (spec §0 documented surface deviation).

```text
1. RED: Write an xt author (POD) failing check first:
   - Extend sdk/xt/ (or add sdk/xt/legacy_build_id_deviation.t) to assert Client.pm POD contains a section naming the three omitted APIs and pointing to the deployment-based replacement (RED: fails while the note is absent; this is a POD-presence check, not a behavior test).
   - Create sdk/t/unit/deployment_versioning_supported.t: assert the deployment-versioning path is exercised and green (the supported replacement works).
2. GREEN: add the deliberate-deviation documentation (no RPC implementation):
   - Edit Client.pm POD: add a section naming update_worker_build_id_compatibility, get_worker_build_id_compatibility, get_worker_task_reachability as deliberately omitted (deprecated, superseded) and pointing to the deployment-based versioning as the supported path (_client.py:2770,2801,2832).
   - Do not implement the three RPCs.
3. REFACTOR: Cross-link the deviation note to the deployment-versioning POD; comment cites client finding 5 and the spec §0 surface-deviation allowance.
4. Verify: POD names the three omitted APIs and the deployment replacement; the deployment-versioning unit test is green; prove -lj4 xt POD coverage stays green; full prove -lj4 t green under the memory guard.
```

---

## Implementation Guidelines

- **One step per commit, always green.** Each step carries its repro AND its fix, so the repro lands green and the suite never goes red. Merged steps (for example R8-R10) are one story; R69 is the exception, landing as four independent commits.
- **Reproduce-first.** Every step's RED must fail for the documented reason before GREEN. Where a step-45 probe is cited, the RED is that probe adapted into a committed test (`sdk/t/`); the scratchpad originals under `scratchpad/verify-45/` are ephemeral.
- **Replay over live where deterministic.** Command-sequence, cancellation-outcome, codec, and interceptor behavior go in `sdk/t/replay/`. Use `sdk/t/integration/` only for genuine timing/live paths; crash/hang repros are subprocess-guarded via `sdk/t/lib/SubprocessGuard.pm`.
- **Memory-safety follows Global Requirement 5** (R1, R2, R3, R6, R16, R28, and R29's cycle): the guard exists in code, a committed test asserts observable ordering/presence, and the test comments carry the code trace.
- **Parity to Python source.** R71-R97 verify against `../sdk-python` at implementation time (spec §0), not from memory; cite the file:line in the test comment.
- **Honor the cluster ordering.** Land R8-R10 before R11/R39/R51, and close R40 last in that cluster; land R71 before or with R22; run R70 last; commit R69's four diffs separately.
- **Shim changes follow the memory guard.** `CARGO_BUILD_JOBS=2`, foreground, retry once at jobs=1 on OOM; then `cargo test`, cbindgen regen, and Alien rebuild in the same commit. (No step here is known shim-touching, but confirm during diagnosis.)
- **Do not weaken existing suites.** No repro may be made to pass by loosening an existing assertion. If a fix changes replay golden output, justify it in the commit message.
- **POD in the same change.** Public-behavior fixes update POD in the same commit; `prove -lj4 xt` stays green. POD and README edits follow the repo writing rules (no em/en dashes, straight quotes, plain voice).

## Success Metrics

- Every acceptance criterion in `spec.md` (R1-R97) has a passing test, observed failing first where behavior changed.
- The full suite is green: `prove -lj4 t` and `prove -lj4 xt` under `sdk/`, `cargo test` in the shim, `dzil test` per touched distribution, all under the CLAUDE.md memory guard.
- Every memory-safety item (R1, R2, R3, R6, R16, R28, R29) carries its committed guard-assertion test with the code trace in comments.
- The step-45 probes cited above exist as committed tests under `sdk/t/`; the scratchpad originals are not referenced anywhere.
- The updates.t parallel flake (R34) no longer reproduces across ten `prove -lj4 t` runs.
- R71-R97 bring the SDK to feature-complete parity with `../sdk-python` on the audited surface, or each open item is a documented deviation under spec §0 (R97).
