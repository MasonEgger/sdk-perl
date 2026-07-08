# sdk-perl Remediation TODO (R1-R97)

Per-sub-step tracker for `plan.md`. Spec: `spec.md`. Each fix step is one green commit carrying its repro AND its fix; reproduce-first (RED fails for the documented reason before GREEN); crash/hang repros run subprocess-guarded; every commit leaves the suite green. Memory-safety items (R1, R2, R3, R6, R16, R28, R29) follow Global Requirement 5. The prior live-hardening tracker is archived at `.ai-sessions/live-hardening/todo.md`.

## Phase P1: Memory Safety and Shutdown

### Step R1+R21: Runtime Shutdown Drain Barrier and Pending-Future Failure
- [x] R1+R21.1 RED: unit test asserts order barrier -> fail-pending -> queue-free, deferred free until the synthetic callback settles, pending future fails with shutdown error within timeout; comments carry the L1/L18 code trace
- [x] R1+R21.2 GREEN: add outstanding-callback barrier + fail_all_pending in Core/Callback.pm; sequence barrier->fail->free at Runtime.pm:252-253 with a typed shutdown error
- [x] R1+R21.3 REFACTOR: centralize the ordered shutdown sequence into one helper; comment cites L1 and L18
- [x] R1+R21.4 Verify: barrier-before-free and fail-within-timeout asserted; cargo test green for the shim counterpart; prove -lj4 t green under the memory guard

### Step R2: Guard Connection Free Against a Dead Runtime
- [x] R2.1 RED: unit test destroys the runtime first, then close and (separately) DESTROY the connection; assert no client_free and no crash; comments cite Client/Connection.pm:50-66, Core/FFI.pm:606-608
- [x] R2.2 GREEN: guard both close and DESTROY with a runtime-liveness check (or strong runtime ref), skipping client_free when the runtime is gone
- [x] R2.3 REFACTOR: factor the guarded free into one method both paths call; comment cites L2
- [x] R2.4 Verify: guard present on both paths; both after-shutdown cases skip client_free without crashing; prove -lj4 t green under the memory guard

### Step R3: Stop Freeing the DevServer Handle on the Timeout Path
- [x] R3.1 RED: unit test forces the timeout arm (stalled future) and asserts the handle free is deferred or skipped while the bridge future is pending; comments cite Test/DevServer.pm:232, Core/FFI.pm:625-628
- [x] R3.2 GREEN: attach the free to the pending bridge future's continuation, or leak with a logged warning on timeout
- [x] R3.3 REFACTOR: isolate the deferred-free continuation into a helper; comment cites L3 and the R46/R33 relationship
- [x] R3.4 Verify: no free while the bridge future is pending; forced-timeout test shows deferral/skip; prove -lj4 t green under the memory guard

### Step R28: Stop Writing Through a COW-Shared Tag Buffer
- [x] R28.1 RED: unit test (adapted cow_tag.pl) asserts a shim write through the tag slot leaves an independent "\0" scalar untouched; audit note lists the scalar_to_buffer write sites
- [x] R28.2 GREEN: force a private non-COW allocation before scalar_to_buffer at Core/Callback.pm:362-363 and Worker/SlotSupplierRegistry.pm:69-70
- [x] R28.3 REFACTOR: route both write sites through one private-buffer helper; comment cites L4
- [x] R28.4 Verify: independent "\0" scalar untouched; audit note enumerates write sites; prove -lj4 t green under the memory guard

### Step R16: Make Evict Iteration Safe Against Sibling Deletion
- [x] R16.1 RED: replay test (adapted probe_l6_freed_iteration.pl) drives an evict whose cancel continuation deletes an unvisited sibling; asserts no freed-value croak and eviction completion sent; also covers self-delete
- [x] R16.2 GREEN: iterate a copied key/value snapshot of %pending at Workflow/Runner.pm:1532-1538
- [x] R16.3 REFACTOR: comment the snapshot with the code trace (:1532-1538, sweeps :2199, :2212) and probe note
- [x] R16.4 Verify: sibling-delete evict completes and sends completion; self-delete survivable; prove -lj4 t green under the memory guard

## Phase P2: Pool Fork-Channel Rework

### Step R4: Make Activity Pool State Per-Instance
- [x] R4.1 RED: prove test (adapted probe_pool_globals.pl) builds two pools with distinct registries and asserts pool A dispatch runs pool A's activity; grep-probe asserts no main:: globals remain
- [x] R4.2 GREEN: replace the ADJUST-block main:: globals at Activity/Pool.pm:29-38, 71-75, 150-151 with per-instance state (the one-time fork-channel redesign)
- [x] R4.3 REFACTOR: name/document the per-instance channel for R5/R18/R19 to extend; comment cites L12
- [x] R4.4 Verify: two-pool dispatch correct; no main:: registry/FD/module globals; prove -lj4 t green under the memory guard

### Step R5: Preserve Error Identity Across the Pool Fork Boundary
- [x] R5.1 RED: prove test (adapted probe_pool_error.pl) asserts a non-retryable ApplicationError returns non-retryable with type/details, and a plain die returns retryable with message intact
- [x] R5.2 GREEN: serialize structured error data across the channel at Activity/Pool.pm:187 and :130; rebuild the failure at Worker/ActivityDispatcher.pm:307-314
- [x] R5.3 REFACTOR: route both sites through one structured encode/decode pair on the R4 channel; comment cites L14 and the Python parity source
- [x] R5.4 Verify: both failure shapes correct; prove -lj4 t green under the memory guard

### Step R18+R19: Pool Fork-Channel: Live Heartbeat Relay and Cancel Delivery
- [x] R18+R19.1 RED: unit test asserts parent sees the heartbeat before the body returns; integration test (offline-skip) asserts no heartbeat timeout for a compliant activity; unit test asserts a running child observes cancel and resolves cancelled
- [x] R18+R19.2 GREEN: extend the R4 channel to a two-directional protocol at Activity/Pool.pm:114-124, 172-174 (live heartbeat) and :161-162 + Worker/ActivityDispatcher.pm:280 (live cancel via Context)
- [x] R18+R19.3 REFACTOR: consolidate both directions into the single R4 fork-protocol module; comment cites L13 and L15
- [x] R18+R19.4 Verify: heartbeat-before-return, no timeout for compliant activity, running child cancels; prove -lj4 t green under the memory guard

### Step R30: Close Inherited gRPC Descriptors in Pool Children
- [x] R30.1 RED: prove test (Linux, skip elsewhere) forks a pool child and asserts core/client gRPC sockets closed via /proc/self/fd while the pool channel fds stay open
- [x] R30.2 GREEN: after fork at Activity/Pool.pm:49-56 (coordinating Worker.pm:633), enumerate and close inherited core/client descriptors, keeping only channel fds
- [x] R30.3 REFACTOR: factor the fd-closing sweep into one whitelisting routine; comment cites L16 and the CLAUDE.md rule
- [x] R30.4 Verify: core/client sockets closed and channel open in the child; prove -lj4 t green under the memory guard

### Step R62: Stop Masking Pool and Worker Error Causes
- [x] R62.1 RED: unit test asserts a pool-child require failure surfaces with the module name, and a finalize die attaches to (not replaces) the saved error
- [x] R62.2 GREEN: surface the require failure at Activity/Pool.pm:98-101; attach finalize failures to the saved error at Worker.pm:576-577 and :855-864
- [x] R62.3 REFACTOR: route both hand-offs through a preserve-cause pattern; comment cites L32
- [x] R62.4 Verify: original require message (with module name) and attached finalize error present; prove -lj4 t green under the memory guard

## Phase P3: Wire Format and Codec

### Step R6: Fix Wide-Character Corruption in RawBytes at the FFI Boundary
- [x] R6.1 RED: t/unit/rawbytes_ffi_bytes.t asserts frame length == bytes written for wide, latin-1, ASCII, and embedded-NUL scalars
- [x] R6.2 GREEN: enforce byte purity in Payload/RawBytes.pm:13-18 and byte-based framing in Core/FFI.pm:522-527
- [x] R6.3 REFACTOR: audit every scalar_to_buffer call site in Core/FFI.pm; add the framed==written comment citing L21
- [x] R6.4 Verify: acceptance criteria mapped; prove -lj4 t (and xt) green under the memory guard

### Step R7: Extend the Payload Codec Boundary to the Full v0.2 Surface
- [x] R7.1 RED: nine per-surface replay tests with a marker codec assert encode outbound / decode inbound, plus the SA-not-wrapped negatives
- [x] R7.2 GREEN: route each v2 surface through the codec in Worker/WorkflowDispatcher.pm:200-249 and :170-181, skipping search attributes
- [x] R7.3 REFACTOR: collapse behind one directional helper; update Converter POD to list covered surfaces; cite R6
- [x] R7.4 Verify: encode/decode and SA-exclusion assertions map across the nine files; prove -lj4 t and xt green under the memory guard

## Phase P4: Post-Cancel Corruption Cluster

### Step R8-R10: Post-Cancel Corruption Cluster
- [x] R8-R10.1a RED: t/replay/repro_post_cancel_cleanup.t (R4) reproduces the "already failed and cannot be ->done" death
- [x] R8-R10.1b RED: t/replay/repro_cancel_plain_future.t (R4b) reproduces the ->result croak / missing completion
- [x] R8-R10.1c RED: t/replay/repro_cancel_ext_signal.t (R4c) reproduces the die in push_activation for the external-signal and external-cancel maps
- [x] R8-R10.2 GREEN: fallback stops failing a live body (Runner :2276-2278/:3297-3306); discriminate cancelled in _build_completion :2851; sweep external maps in _apply_cancel_workflow :2188-2278
- [x] R8-R10.3 REFACTOR: unify the per-map sweep from one list; comment citing R4/R4b/R4c
- [x] R8-R10.4 Verify: cleanup command completes, CancelWorkflowExecution outcome produced, external maps observe Cancelled; prove -lj4 t green under the memory guard

### Step R11: Always Send a Completion for a Failed Activation
- [x] R11.1 RED: t/replay/failed_activation_completion.t (pending-future :Query) and subprocess-guarded t/integration/failed_activation_no_wedge.t assert a failed completion, not a die/wedge
- [x] R11.2 GREEN: catch-all in Worker/WorkflowDispatcher.pm:89-128 mapping die to failed completion; stop the warn-and-swallow in Worker/PollLoop.pm:46-50
- [x] R11.3 REFACTOR: centralize the die-to-failed-completion mapping for the Runner.pm trigger sites; comment citing R5
- [x] R11.4 Verify: failed-completion and no-wedge assertions map; prove -lj4 t green under the memory guard

### Step R39: Add the Missing on_cancel Hook to Child-Workflow Signals
- [x] R39.1 RED: t/replay/child_signal_cancel.t asserts a cancelled pending child signal emits CancelSignalWorkflow (and no double-emit when resolved first)
- [x] R39.2 GREEN: add the on_cancel hook to _signal_child_workflow in Workflow/Runner.pm:908-936, mirroring :996-1010
- [x] R39.3 REFACTOR: factor the shared cancel-emits-command logic so child/external arms cannot drift; comment citing R10
- [x] R39.4 Verify: cancel-emits-command and no-double-emit assertions map; prove -lj4 t green under the memory guard

### Step R51: Correct the Pre-Scheduled-Cancel Comment in Runner
- [ ] R51.1 RED: guard in t/unit/runner_comments.t fails while the stale "pre-scheduled cancel" phrasing remains at Runner.pm:1188-1193
- [ ] R51.2 GREEN: rewrite the :1188-1193 comment to the real _apply_cancel_workflow fallback mechanism post-R8-R10; fix the contradicting nexus arm comment
- [ ] R51.3 REFACTOR: ensure the comment cites finding R3 and the fixed behavior
- [ ] R51.4 Verify: guard passes plus reviewer sign-off in the commit message; prove -lj4 t green under the memory guard

### Step R40: Cover the Post-Cancel Paths in the Replay Suite
- [ ] R40.1 RED: add t/replay/post_cancel_child_workflow.t, post_cancel_timer.t, post_cancel_local_activity.t in catch-and-cleanup and propagate shapes
- [ ] R40.2 GREEN: no product code (behavior fixed by R8-R10); any failure is a real gap traced back to the cluster
- [ ] R40.3 REFACTOR: header each file mapping it to finding T8 and its arm; keep the four-arm ledger visible
- [ ] R40.4 Verify: four arms covered in both shapes (activity via R8-R10 repros); closed LAST in the cluster; prove -lj4 t green under the memory guard

## Phase P5: Cancellation Semantics

### Step R12+R52+R53: Cancellation-Type Test File
- [ ] R12+R52+R53.1 RED: replay cancellation_types.t covers WAIT vs TRY_CANCEL regular activity, evict of wait-type LA, and double-cancel LA
- [ ] R12+R52+R53.2 GREEN: honor WAIT_CANCELLATION_COMPLETED on the regular-activity arm, make evict cancel LAs unconditionally, add at-most-once LA cancel guard
- [ ] R12+R52+R53.3 REFACTOR: share one wait-type helper across both activity arms; cite R7/L8/L10 + Python parity
- [ ] R12+R52+R53.4 Verify: pending-until-resolution, TRY_CANCEL-unchanged, eviction-completes, exactly-one-cancel assertions pass; prove -lj4 t green

### Step R13: Keep Query and Update Responses on Failure Completions
- [ ] R13.1 RED: replay failure_keeps_responses.t asserts query and update responses survive a same-activation failure; mutating commands dropped
- [ ] R13.2 GREEN: partition @commands at Runner.pm:3054, retain handler responses, correct the false Python comment
- [ ] R13.3 REFACTOR: extract is_handler_response_command predicate; cite R9 + Python source
- [ ] R13.4 Verify: response-present and mutating-dropped assertions pass; prove -lj4 t green

### Step R14+R15: Route workflow_failure_exception_types and nondeterminism_as_workflow_fail to Live Runners
- [ ] R14+R15.1 RED: unit dispatcher_failure_options.t asserts both options reach the live Runner; replay failure_exception_types.t asserts workflow vs task failure
- [ ] R14+R15.2 GREEN: reroute both options from core's workflow-type field into the live Runner constructor at Worker.pm:459-460 / WorkflowDispatcher.pm:170-181
- [ ] R14+R15.3 REFACTOR: name the plumbing keys once so live and replay share them; cite A1/ADJ2
- [ ] R14+R15.4 Verify: unit-arrival and replay outcome assertions (listed-type + nondeterminism) pass; prove -lj4 t green

### Step R17: Settle Updates from Cancelled Handler Futures Without Croaking
- [ ] R17.1 RED: replay evict_pending_update.t (no croak, eviction completes) + unit settle_update_states.t (done/failed/cancelled)
- [ ] R17.2 GREEN: discriminate the cancelled future in _settle_update before ->result and settle per the eviction contract
- [ ] R17.3 REFACTOR: factor a settle-core sub; embed the probe state table; cite L7
- [ ] R17.4 Verify: no-croak eviction and three-state settle assertions pass; prove -lj4 t green

### Step R23+R50: Make the Shared Cancellation Future Survive wait_any (with Direct ChildCancellation Tests)
- [ ] R23+R50.1 RED: cancellation.t wait_any-double-race then later-consumer-observes; new child_cancellation.t covers construction, observation, and the race
- [ ] R23+R50.2 GREEN: cancelled() returns a per-call derived (or ->without_cancel) future in Cancellation.pm and Activity/ChildCancellation.pm
- [ ] R23+R50.3 REFACTOR: share the derivation helper; add POD documenting the safe-to-race contract; cite R2/T2
- [ ] R23+R50.4 Verify: both classes' second-consumer-observes assertions pass; prove -lj4 t and xt green

### Step R24: Enforce Read-Only Context and Writability Asserts Uniformly
- [ ] R24.1 RED: replay query_readonly.t table-drives the four bypassing APIs raising the typed read-only error in query context; unchanged in writable context
- [ ] R24.2 GREEN: add _assert_writable at the four sites and run query handlers in a read-only context that raises on command emission
- [ ] R24.3 REFACTOR: table-drive the guard so new APIs inherit it; cite R8 + Python read-only parity
- [ ] R24.4 Verify: each API raises in query context and works in writable context; prove -lj4 t green

### Step R20: Isolate Exceptions Per Entry in the Callback Drain Loop
- [ ] R20.1 RED: unit callback.t enqueues a chunk with a dying middle entry; asserts later entries still run and the death is captured
- [ ] R20.2 GREEN: wrap each per-entry continuation in its own eval at Core/Callback.pm:322-331,:463-467; log and continue
- [ ] R20.3 REFACTOR: factor a guarded-invoke helper for both drain sites; cite L17
- [ ] R20.4 Verify: all non-dying entries ran despite the middle death; prove -lj4 t green

## Phase P6: Workflow and Client Semantics

### Step R25: Send search_attributes and versioning_intent on Continue-as-New
- [ ] R25.1 RED: replay continue_as_new_options.t asserts both fields present with values when set, proto defaults when omitted
- [ ] R25.2 GREEN: carry both options into the ContinueAsNewWorkflowExecution command at Runner.pm:2933-2980 using confirmed proto field names
- [ ] R25.3 REFACTOR: reuse the shared search-attribute encoder; cite R11 + proto path
- [ ] R25.4 Verify: present-with-values and omitted-defaults assertions pass; prove -lj4 t green

### Step R26: Deliver Init Signals Before the Main Routine Starts
- [ ] R26.1 RED: replay init_signal_ordering.t asserts an init-activation signal handler's side effect is visible to the main routine's prologue
- [ ] R26.2 GREEN: apply same-activation signal jobs before the main routine's synchronous prologue at Runner.pm:2317-2319,:1709,:1716
- [ ] R26.3 REFACTOR: make the signals-before-main job order explicit; cite R12 + ../sdk-python ordering
- [ ] R26.4 Verify: handler-visible-to-prologue assertion passes and post-start signals still work; prove -lj4 t green

### Step R27+R38: Determinism-Guard Install Point and Override Accountability
- [ ] R27+R38.1 RED: subprocess-guarded determinism_guard_load_order.t (pre-loaded workflow trips the guard) + unit determinism_guard.t (stock time/rand outside workflow context)
- [ ] R27+R38.2 GREEN: install/arm the guard at Definition registration; keep overrides transparent passthroughs outside workflow context with a defined uninstall/permanence decision
- [ ] R27+R38.3 REFACTOR: route R27 and R38 through one install point; document the override lifecycle in Worker POD; cite R13/A15
- [ ] R27+R38.4 Verify: guard-trips-for-preloaded and stock-outside-context assertions pass; prove -lj4 t and xt green

### Step R29: Break the Start-Future Ownership Cycle in Handles
- [ ] R29.1 RED: unit handle_start_cycle.t asserts DESTROY runs (weak-ref liveness) for ChildWorkflowHandle and NexusOperationHandle after refs drop
- [ ] R29.2 GREEN: resolve start futures with a non-owning token (or weaken the back-reference) at Runner.pm:895-897 and the two handle classes
- [ ] R29.3 REFACTOR: centralize any token-for-handle exchange; cite L5 and flag the same shape elsewhere
- [ ] R29.4 Verify: both DESTROY-after-drop assertions pass and callers still get the handle; prove -lj4 t green

### Step R31: Honor Pending Futures from Custom Slot Suppliers
- [ ] R31.1 RED: unit slot_supplier_pending.t asserts no permit while the reserve future is pending and the permit matches the resolved value
- [ ] R31.2 GREEN: defer the permit for a pending reserve future in _resolve_permit at SlotSupplierRegistry.pm:102-117,:141-148
- [ ] R31.3 REFACTOR: clearly name the pending-vs-resolved branch; cite L19 + shim reserve-timing note
- [ ] R31.4 Verify: no-permit-while-pending and permit-matches-value assertions pass; prove -lj4 t green

### Step R32: Implement Nexus cancel_task
- [ ] R32.1 RED: extend replay nexus.t to dispatch a task, deliver cancel_task, and assert the operation future is cancelled and ack_cancel fires
- [ ] R32.2 GREEN: register running operations in %running and wire cancel_task to cancel the future and send ack_cancel at NexusDispatcher.pm:109,:93-98,:350-353
- [ ] R32.3 REFACTOR: pair register/deregister across completion, failure, and cancel; cite L20
- [ ] R32.4 Verify: cancel-and-ack assertions pass and a normal op still completes/deregisters; prove -lj4 t green

### Step R36: Complete the Workflow info() Surface
- [ ] R36.1 RED: replay workflow_info.t asserts workflow_id, attempt, task_queue carry init-activation values; existing fields unchanged
- [ ] R36.2 GREEN: populate the three fields from init data at Runner.pm:391-407 and correct the POD at Workflow.pm:470-471
- [ ] R36.3 REFACTOR: source all info() fields from one init struct; cite A5 + Python info() field list
- [ ] R36.4 Verify: three-fields assertion passes; xt POD green; prove -lj4 t and xt green

### Step R35: Validate Activity Options at the Call Site
- [ ] R35.1 RED: replay activity_option_validation.t asserts typed error for no-timeout and unknown-key (both activity kinds); valid call succeeds
- [ ] R35.2 GREEN: require a timeout and reject unknown keys with Temporalio::Exception::Argument at Runner.pm:449-511 and :562 onward
- [ ] R35.3 REFACTOR: factor a shared known-keys + required-timeout validator (aligned with R44/R55); cite A2
- [ ] R35.4 Verify: no-timeout-raises, unknown-key-raises, and valid-succeeds assertions pass by class; prove -lj4 t green

### Step R44: Unify Unknown-Option Strictness on the Client Surface
- [ ] R44.1 RED: unit client_option_strictness.t sweeps public client methods asserting the typo raises the typed error; known keys accepted
- [ ] R44.2 GREEN: reject unknown option keys at Client/WorkflowHandle.pm:56 via the shared validator (Temporalio::Exception::Argument)
- [ ] R44.3 REFACTOR: extract one client-surface unknown-option validator aligned with R35; cite A10
- [ ] R44.4 Verify: typo-raises sweep passes and known keys still pass; prove -lj4 t green

### Step R55: Raise Typed Errors for Missing Workflow-Context Arguments
- [ ] R55.1 RED: replay workflow_arg_errors.t asserts Temporalio::Exception::Argument by class at Runner.pm:451-453 and :579-581
- [ ] R55.2 GREEN: replace the plain string dies with the typed throw, reusing the R35 validator where the region overlaps
- [ ] R55.3 REFACTOR: route both sites through the shared argument-validation helper; cite A14
- [ ] R55.4 Verify: both sites raise catchable typed errors asserted by class; prove -lj4 t green

### Step R37: Wire or Reject start_workflow Extended Options
- [ ] R37.1 RED: unit start_workflow_extended_options.t captures the request and asserts static_summary/static_details in user-metadata and versioning_override wired (or typed-reject)
- [ ] R37.2 GREEN: stop deleting the three options at Client.pm:572-574; wire summary/details to user-metadata and versioning_override to its field, else raise the typed error
- [ ] R37.3 REFACTOR: reuse the user-metadata encoding helper; cite A7 + Python encoding
- [ ] R37.4 Verify: fields-in-request (or typed-reject) assertions pass; prove -lj4 t green + start_workflow.t skip_all offline

## Phase P7: Test Infrastructure and Tracing

### Step R33+R46+R47+R48: DevServer and Test-Helper Future-State Fixes
- [ ] R33+R46+R47+R48.1 RED: unit tests in devserver_shutdown.t (shared with R3) + test_await_helpers.t force timeout/throw/wedge cases with the adapted future_semantics probe
- [ ] R33+R46+R47+R48.2 GREEN: reap late completions (DevServer:174-187, Client:39-57), flag-after-success (DevServer:207-208), reachable diagnostics (DevServer:35-37, Worker:45-46), reachable retry (Client:43-51)
- [ ] R33+R46+R47+R48.3 REFACTOR: factor the shared wait_any loser-reaper helper; comment each site with L26/T5/T6 and the Future 0.52 state
- [ ] R33+R46+R47+R48.4 Verify: reaper observed, retryable shutdown, diagnostic text, connect retry; prove -lj4 t and xt green

### Step R34+R61: Remove the Ephemeral-Port Race and Fix the Net::EmptyPort Dependency Phase
- [ ] R34+R61.1 RED: concurrent four-server integration test (skip_all offline) + emptyport_range unit probe + cpanfile dependency-audit assertion
- [ ] R34+R61.2 GREEN: race-free port strategy at DevServer:109,:143; drop-or-rephase Net::EmptyPort in DevServer:12 and cpanfile
- [ ] R34+R61.3 REFACTOR: comment the port site with T-flake and the chosen strategy; note R34/R61 coupling
- [ ] R34+R61.4 Verify: no bind failure/cross-connect, updates.t flake gone, cpanfile phase matches uses; prove -lj4 t and xt green

### Step R49: Register Dev-Server Teardown in END Blocks
- [ ] R49.1 RED: xt/devserver_end_teardown.t statically asserts END-block teardown in every DevServer-using integration file (fails now)
- [ ] R49.2 GREEN: move/add END-block teardown to each flagged t/integration/*.t per updates.t:176-179
- [ ] R49.3 REFACTOR: comment the xt probe with T9 and the DevServer:244-251 hazard
- [ ] R49.4 Verify: xt probe passes; die no longer orphans CLI; prove -lj4 t and xt green

### Step R43: Make WorkflowReplay's Nondeterminism Claim True or Scoped
- [ ] R43.1 RED: implemented -> t/replay/nondeterminism.t on mutated history; scoped -> xt grep probe for the overclaim
- [ ] R43.2 GREEN: engage core replayer at WorkflowReplay:59-95, or scope README:545-552 and POD; record direction in commit
- [ ] R43.3 REFACTOR: comment WorkflowReplay:59 with R14 and the chosen direction
- [ ] R43.4 Verify: mutated-history error or grep finds no overclaim; prove -lj4 t and xt green

### Step R45: Revive the Dead Nexus Integration Test
- [ ] R45.1 RED: perl -c on t/integration/nexus.t fails on with_worker and the API misuse
- [ ] R45.2 GREEN: fix with_worker (:74-77), connect positionals (:90), iterator consumption (:103-108); keep skip_all offline
- [ ] R45.3 REFACTOR: align with nearest working integration file; comment with T7
- [ ] R45.4 Verify: perl -c passes offline, prove -l passes with server, skip_all offline; prove -lj4 t and xt green

### Step R22+R41+R42: Implement the OpenTelemetry TracingInterceptor and Point Its Tests at the Wired Behavior
- [ ] R22+R41+R42.1 RED: rewrite t/unit/tracing.t on the fake-tracer scaffold to assert span creation per surface, header round-trip, R41 mutation note, R42 OTel-installed fixture
- [ ] R22+R41+R42.2 GREEN: implement spans + header inject/extract at TracingInterceptor:205-233 matching Python contrib; correct POD at :286-290
- [ ] R22+R41+R42.3 REFACTOR: extract span-naming/header-carrier helpers; comment with R1; note samples-perl R3 can lift
- [ ] R22+R41+R42.4 Verify: spans/headers asserted, revert fails tests, gated subtest passes with/without OTel, POD matches; prove -lj4 t and xt green

### Step R70: Convert Offline-Skipping Repro Guards to Replay Tests
- [ ] R70.1 RED: new t/replay/<name>.t per convertible guard using the R8-R10 harness; each fails if the fix reverts (run LAST)
- [ ] R70.2 GREEN: move convertible assertions into replay tests; keep server-only guards with a why comment
- [ ] R70.3 REFACTOR: align new replay files with harness conventions; comment with T10
- [ ] R70.4 Verify: offline suite fails on any reintroduced regression; server-only guards justified; prove -lj4 t and xt green

## Phase P8: Converter, POD, and Parity Edges

### Step R56-R59: Converter Batch
- [ ] R56-R59.1 RED: converter_errors.t for poisoned failure converter, malformed UTF-8, empty-data json/plain; xt pod check for BinaryPlain/Json claim conditions
- [ ] R56-R59.2 GREEN: wrap failure errors (Data:152-153,:182), check utf8::decode (JsonProtobuf:48), define empty-data outcome, fix POD (BinaryPlain:25-27 + Json)
- [ ] R56-R59.3 REFACTOR: comment sites with L22/L23/ADJ1/L24; note R57/R68 shared probe
- [ ] R56-R59.4 Verify: typed wrapper, UTF-8 raise, empty-data Python parity, POD maps to code; prove -lj4 t and xt green

### Step R64-R66: POD Pass
- [ ] R64-R66.1 RED: xt grep probe for "arrives later"; xt kwarg-vs-POD cross-check for Worker->new and connect; list_workflows behavior test
- [ ] R64-R66.2 GREEN: fix list_workflows POD (Client:275-281,:1109-1111); strip stale POD (Client:1010-1011, Worker:1060-1063, Activity:74-79); document all kwargs + connect options
- [ ] R64-R66.3 REFACTOR: keep the xt cross-check general; comment with A9/A11/A12
- [ ] R64-R66.4 Verify: grep returns nothing, xt cross-check passes, return type matches test; prove -lj4 t and xt green

### Step R54: Ship the Promised Workflow memo and search_attributes Readers
- [ ] R54.1 RED: t/replay/workflow_memo_sa_readers.t reads both before and after an upsert
- [ ] R54.2 GREEN: add memo and search_attributes readers in Workflow.pm/Runner.pm returning current values, Python-parity shapes
- [ ] R54.3 REFACTOR: source readers from the upsert-written state; comment with A6 and archived spec lines
- [ ] R54.4 Verify: initial then updated values returned; xt pod covers readers; prove -lj4 t and xt green

### Step R60: Align Metric-Drop Behavior with Its Documentation
- [ ] R60.1 RED: metric_meter_drop.t asserts documented unbound-record behavior and warn rate-limiting
- [ ] R60.2 GREEN: buffer-until-bound or document the drop window at MetricMeter:46-52; rate-limit the warning at :217-218,:130
- [ ] R60.3 REFACTOR: comment with L28 and the chosen direction; make doc and code agree
- [ ] R60.4 Verify: unbound path matches doc, warn rate-limited, decision in commit; prove -lj4 t and xt green

### Step R63: Accept the Spec-Promised Workflow Argument Forms in start_workflow
- [ ] R63.1 RED: start_workflow_argforms.t passes a definition class and a ref, asserts resolved type in the request, keeps string form
- [ ] R63.2 GREEN: accept definition-class and ref forms at Client:617-625, resolve to the workflow type name
- [ ] R63.3 REFACTOR: reuse existing type-name resolution; comment with A8 and the archived spec promise
- [ ] R63.4 Verify: both forms resolve, string form unchanged; prove -lj4 t and xt green

### Step R67: Map and Validate query reject_condition
- [ ] R67.1 RED: query_reject_condition.t covers each named value's enum mapping and one invalid value raising the typed error
- [ ] R67.2 GREEN: map names to the proto enum at WorkflowHandle:379-381, raise on invalid, add POD with Python-parity names
- [ ] R67.3 REFACTOR: single-source the name-to-enum map near the proto enum; comment with A13
- [ ] R67.4 Verify: named values map, invalid raises, POD lists names; prove -lj4 t and xt green

### Step R68: Accept Non-Temporalio Causes in Exception Chaining
- [ ] R68.1 RED: exception_cause_chaining.t chains a plain string die and a foreign object (adapted probe cause assertions)
- [ ] R68.2 GREEN: accept any defined cause at Exception:20-27; stringify/store non-exception causes per contract
- [ ] R68.3 REFACTOR: document the cause contract in POD; comment with A16 and the shared probe
- [ ] R68.4 Verify: string die and foreign object survive as causes, POD states contract; prove -lj4 t and xt green

### Step R69: Close the Four Verified Cross-SDK Divergences
- [ ] R69.1 RED: four tests: parity_backfills, parity_activity_priority_summary, parity_list_page_size, parity_execute_update_wait_for_stage
- [ ] R69.2a GREEN (commit 1): add schedule backfills kwarg wired to proto
- [ ] R69.2b GREEN (commit 2): add activity priority/summary options carried to the command
- [ ] R69.2c GREEN (commit 3): send page-size defaults on list calls
- [ ] R69.2d GREEN (commit 4): stop execute_update overriding the caller's wait_for_stage
- [ ] R69.3 REFACTOR: per-diff comment citing A17 and the checked Python behavior
- [ ] R69.4 Verify: one passing assertion per item, four separate commits; prove -lj4 t and xt green

## Phase P9: Parity — Interceptor and High-Value Gaps

### Step R71: Wire and Invoke the Workflow-Outbound Interceptor Chain
- [ ] R71.1 RED: replay test asserting outbound execute_activity/start_child_workflow interceptor mutations reach the emitted command; fails on unwired base
- [ ] R71.2 GREEN: give WorkflowOutbound the eight methods, build the root outbound, fold interceptors, call inbound->init(outbound), route ops through the chain (Interceptor.pm, Runner.pm:1690)
- [ ] R71.3 REFACTOR: extract outbound-chain construction into a helper; comment citing parity finding 1 / _interceptor.py:416-481
- [ ] R71.4 Verify: mutation-reaches-command assertions green; prove -lj4 t green under the memory guard

### Step R72: Add the Activity-Outbound Interceptor and Wire ActivityInbound.init
- [ ] R72.1 RED: unit test asserting an activity interceptor's outbound heartbeat override fires when the body calls heartbeat
- [ ] R72.2 GREEN: add ActivityOutbound (info, heartbeat), build root outbound and call inbound->init(outbound) (ActivityDispatcher.pm:152), route Context heartbeat/info through it
- [ ] R72.3 REFACTOR: share the fold-over-root helper with R71; comment citing parity finding 2 / _interceptor.py:135-156
- [ ] R72.4 Verify: override-fires assertion green; prove -lj4 t green under the memory guard

### Step R73: Add the Nexus Operation Inbound Interceptor Role
- [ ] R73.1 RED: unit test asserting a nexus-start interceptor override runs before the handler body (and cancel override wraps the handler)
- [ ] R73.2 GREEN: add intercept_nexus_operation and NexusOperationInbound (start/cancel), fold interceptors over a handler-running root in NexusDispatcher.pm:196,257
- [ ] R73.3 REFACTOR: unify the nexus fold with the R71/R72 helper; comment citing parity finding 3 / _interceptor.py:66-78,500-528
- [ ] R73.4 Verify: override-before-handler assertion green; prove -lj4 t green under the memory guard

### Step R74: Carry ApplicationError next_retry_delay Through Exception and Failure Proto
- [ ] R74.1 RED: unit test round-tripping next_retry_delay through to_failure/from_failure and asserting the proto field is set
- [ ] R74.2 GREEN: accept next_retry_delay on ApplicationError (Application.pm:11-14) and map it to/from ApplicationFailureInfo.next_retry_delay (Failure.pm:231-240,251-261)
- [ ] R74.3 REFACTOR: centralize Duration<->seconds conversion; comment citing parity finding 1 / message.proto:27
- [ ] R74.4 Verify: survives round-trip and appears in proto field; prove -lj4 t green under the memory guard

### Step R75: Support encode_common_attributes on the Failure Converter
- [ ] R75.1 RED: test with encode_common_attributes on + marker codec asserting on-wire message "Encoded failure" and codec-tagged encoded_attributes, and from_failure recovery
- [ ] R75.2 GREEN: accept encode_common_attributes; to_failure relocates message/stack_trace into encoded_attributes, from_failure restores (Failure.pm)
- [ ] R75.3 REFACTOR: name the "Encoded failure" sentinel constant; comment citing parity finding 2 / _failure_converter.py:312-327
- [ ] R75.4 Verify: on-wire encoded + recovery assertions green; prove -lj4 t green under the memory guard

### Step R76: Expose Activity Cancellation Details and Reason
- [ ] R76.1 RED: unit test delivering WORKER_SHUTDOWN and PAUSED cancels and asserting the context reports the matching reason and details
- [ ] R76.2 GREEN: capture Cancel reason + ActivityCancellationDetails (ActivityDispatcher.pm:105-113) and add a cancellation_details accessor on Context.pm
- [ ] R76.3 REFACTOR: fix Context POD conflating server-cancel with worker-shutdown; comment citing worker finding 2 / _activity.py:221-226
- [ ] R76.4 Verify: reason/details assertions green; prove -lj4 t and xt green under the memory guard

### Step R77: Add workflow.uuid4 Deterministic UUID
- [ ] R77.1 RED: replay test asserting uuid4() is a valid v4, stable across replay, differs from a second call, and is seeded from the activation randomness seed
- [ ] R77.2 GREEN: add Workflow::uuid4 returning a v4 UUID from the workflow deterministic RNG (Workflow.pm)
- [ ] R77.3 REFACTOR: reuse the existing deterministic RNG; comment citing in-workflow finding 1 / _context.py:866
- [ ] R77.4 Verify: stability/uniqueness/seed assertions green; prove -lj4 t and xt green under the memory guard

### Step R78: Carry a Summary on Timers, sleep, and wait_condition Timeouts
- [ ] R78.1 RED: replay test asserting StartTimer carries the user-metadata summary when passed (sleep/start_timer/wait_condition) and none when omitted
- [ ] R78.2 GREEN: sleep/start_timer accept summary, wait_condition accepts timeout_summary, Runner emits StartTimer user-metadata (Workflow.pm:241,250; Runner.pm:1220,1366,1388)
- [ ] R78.3 REFACTOR: reuse the local-activity user-metadata summary builder; comment citing in-workflow finding 2 / _context.py:878,894
- [ ] R78.4 Verify: summary-present/absent assertions green; prove -lj4 t green under the memory guard

### Step R79: Expose Per-Activation Workflow Info Accessors
- [ ] R79.1 RED: replay test driving an activation with history_length, history_size_bytes, build_id, continue_as_new_suggested and asserting each accessor returns the delivered (and updated) value
- [ ] R79.2 GREEN: capture the four per-activation fields and expose get_current_history_length/size, get_current_build_id, is_continue_as_new_suggested (Runner.pm)
- [ ] R79.3 REFACTOR: store the four fields in one per-activation struct updated at the boundary; comment citing in-workflow finding 3 / _context.py:140-185
- [ ] R79.4 Verify: per-activation accessor assertions green; prove -lj4 t and xt green under the memory guard

### Step R80: Add the max_concurrent_nexus_tasks Worker Kwarg
- [ ] R80.1 RED: unit test asserting max_concurrent_nexus_tasks => N packs a FixedSize nexus supplier of N, unset keeps 100, and alongside tuner throws mutual-exclusion
- [ ] R80.2 GREEN: accept the kwarg (Worker.pm:60-62), feed the synthesized fixed tuner (Worker.pm:300,416), add to mutual-exclusion set (Worker.pm:959-961)
- [ ] R80.3 REFACTOR: fold into the existing max_concurrent_* handling; comment citing worker finding 1 / _worker.py:129-133
- [ ] R80.4 Verify: supplier-packing and mutual-exclusion assertions green; prove -lj4 t green under the memory guard

### Step R81: Add fairness_key and fairness_weight to Priority
- [ ] R81.1 RED: unit test asserting to_proto sets priority_key, fairness_key, and fairness_weight (and leaves the latter two unset when absent)
- [ ] R81.2 GREEN: accept fairness_key (string) and fairness_weight (float) and encode both into Priority (Common/Priority.pm)
- [ ] R81.3 REFACTOR: validate fairness_weight type at construction as Python does; comment citing schedule/runtime finding 3 / message.proto:344,354
- [ ] R81.4 Verify: three-field to_proto assertion green; prove -lj4 t green under the memory guard

### Step R82: Encode static_summary and static_details on the Schedule Action
- [ ] R82.1 RED: request-capture/replay test asserting static_summary and static_details appear as encoded payloads in the emitted NewWorkflowExecutionInfo.user_metadata (none when absent)
- [ ] R82.2 GREEN: StartWorkflow accepts static_summary/static_details (Action.pm:28-39) and _to_proto encodes them into user_metadata (Action.pm:73-124)
- [ ] R82.3 REFACTOR: reuse the R37 user-metadata payload builder; comment citing schedule/runtime finding 1 / _schedule.py:551-552
- [ ] R82.4 Verify: user_metadata payload assertions green; prove -lj4 t green under the memory guard

## Phase P10: Parity — Medium and Low

### Step R83: Expose a User-Facing Metric Meter in Workflow, Activity, and Nexus Context
- [ ] R83.1 RED: replay + unit tests: workflow counter emits live and is suppressed on replay; activity + nexus counters reach a test buffer
- [ ] R83.2 GREEN: add emission surface to Runtime/MetricMeter.pm; expose metric_meter on activity/workflow/nexus contexts (workflow no-ops on replay), to Python parity
- [ ] R83.3 REFACTOR: share one instrument wrapper across the three contexts; comment cites parity finding 6 + replay suppression
- [ ] R83.4 Verify: live emit, replay suppress, activity + nexus emit; prove -lj4 t green under memory guard

### Step R84: Provide Worker-Shutdown Detection Inside Activities
- [ ] R84.1 RED: unit test: worker shutdown flips is_worker_shutdown and resolves the shutdown future; a plain cancel does not
- [ ] R84.2 GREEN: add distinct worker-shutdown event/future to Activity/Context.pm:28-30; fire it at shutdown-begin, to activity.py:400-438 parity
- [ ] R84.3 REFACTOR: name the event/future per Python; comment cites finding 4 + shutdown-vs-cancel
- [ ] R84.4 Verify: shutdown observed distinctly from cancel; prove -lj4 t green under memory guard

### Step R85: Complete Activity Info with priority and retry_policy
- [ ] R85.1 RED: unit test: start job with retry_policy + priority surfaces both on activity Info; neither present yields empty without error
- [ ] R85.2 GREEN: populate priority and retry_policy in Worker/ActivityDispatcher.pm:320-341, Python activity.py:130-136 naming
- [ ] R85.3 REFACTOR: reuse existing priority/retry mappers; comment cites finding 5
- [ ] R85.4 Verify: both fields surface when set and stay absent when omitted; prove -lj4 t green under memory guard

### Step R86: Support Runtime Signal, Query, and Update Handler Registration
- [ ] R86.1 RED: replay test: runtime-set signal handler runs; a buffered pre-registration signal drains on registration; getters return installed handlers
- [ ] R86.2 GREEN: add set_*_handler/get_*_handler to Workflow.pm/Workflow/Runner.pm with buffered-drain, to _workflow_ops.py:833-985 parity
- [ ] R86.3 REFACTOR: unify compile-time and runtime handler tables behind one lookup; comment cites finding 4 + buffered drain
- [ ] R86.4 Verify: runtime handler runs, buffered signal drains, getters work; prove -lj4 t green under memory guard

### Step R87: Honor Per-Handler HandlerUnfinishedPolicy
- [ ] R87.1 RED: replay test: in-flight ABANDON update handler completes with no warning; default policy still warns; signal honors the option
- [ ] R87.2 GREEN: parse unfinished_policy in Workflow/Attributes.pm; consult it at Workflow.pm:418-421, to _handlers.py:36 parity
- [ ] R87.3 REFACTOR: thread policy through the handler descriptor; comment cites finding 5 + default-warn/opt-out
- [ ] R87.4 Verify: ABANDON no warning, default warns, signal honors policy; prove -lj4 t green under memory guard

### Step R88: Expose Last-Completion-Result and Last-Failure
- [ ] R88.1 RED: replay test: seeded last-completion-result decodes via has_/get_last_completion_result; seeded last_failure types via get_last_failure; absent fields report false/undef
- [ ] R88.2 GREEN: capture and surface the carry-over fields from Workflow/Runner.pm, exposed on Workflow.pm, to _context.py:675,688,696 parity
- [ ] R88.3 REFACTOR: decode lazily on first access; comment cites finding 7
- [ ] R88.4 Verify: result decodes, failure types, absent reports false/undef; prove -lj4 t green under memory guard

### Step R89: Restore Dropped Nexus Handler-Context Capabilities
- [ ] R89.1 RED: unit test: dispatched nexus op has OperationInfo->namespace = worker namespace; is_worker_shutdown flips true on dispatcher drain and waiters resolve
- [ ] R89.2 GREEN: add namespace to OperationInfo (Nexus/OperationContext.pm:18-28); add wait_for_worker_shutdown/_sync and set the shutdown flag in Nexus.pm, to _operation_context.py:82-147 parity
- [ ] R89.3 REFACTOR: share the shutdown-flip with R84 if adjacent; comment cites nexus finding 4
- [ ] R89.4 Verify: namespace matches, shutdown flips on drain, waiters resolve; prove -lj4 t green under memory guard

### Step R90: Implement Lazy Client Connections
- [ ] R90.1 RED: subprocess-guarded integration test: lazy connect to an unreachable target succeeds; connect attempted only on first RPC; eager path unchanged
- [ ] R90.2 GREEN: remove the stale throw at Client.pm:817,829-831; defer connect to first RPC when lazy, to _client.py:151,205-207 parity
- [ ] R90.3 REFACTOR: once-init guard so concurrent first RPCs share one connect; comment cites finding 3 + removes stale v0.1 message
- [ ] R90.4 Verify: lazy construct ok, connect on first RPC, eager unchanged; prove -lj4 t green under memory guard

### Step R91: Expose Raw Service Clients on the Client
- [ ] R91.1 RED: subprocess-guarded integration test (skip_all offline): operator-service RPC forms/sends via the raw handle; workflow-service raw RPC round-trips
- [ ] R91.2 GREEN: expose a low-level WorkflowService/OperatorService handle in Client/Connection.pm + workflow_service/operator_service accessors on Client.pm, to _client.py:307-322 parity
- [ ] R91.3 REFACTOR: generate the RPC method map from proto service descriptors; comment cites finding 1
- [ ] R91.4 Verify: operator RPC forms/sends, workflow raw RPC round-trips; prove -lj4 t green under memory guard

### Step R92: Add WorkflowHandle get_update_handle
- [ ] R92.1 RED: subprocess-guarded integration test: get_update_handle result polls PollWorkflowExecutionUpdate with the given update id + handle's run id; omitted run_id binds the handle's run
- [ ] R92.2 GREEN: add get_update_handle(update_id, run_id, result_type) to Client/WorkflowHandle.pm via the public update-handle constructor, to _workflow.py:978,1008 parity
- [ ] R92.3 REFACTOR: default run/workflow id from the handle in one place; comment cites finding 2
- [ ] R92.4 Verify: polls with correct update + run id; prove -lj4 t green under memory guard

### Step R93: Honor a Client-Level Default Query Reject Condition
- [ ] R93.1 RED: subprocess-guarded integration test: connect default rides the outbound QueryWorkflow when per-call omitted; per-call value overrides; neither leaves it unset
- [ ] R93.2 GREEN: accept/store default_workflow_query_reject_condition at Client.pm:800-824; apply it in Client/WorkflowHandle.pm:379-380 when per-call absent, to _client.py:144-145,184-187 parity
- [ ] R93.3 REFACTOR: resolve the effective condition in one shared helper; comment cites finding 4
- [ ] R93.4 Verify: default applied, per-call overrides, unset stays unset; prove -lj4 t green under memory guard

### Step R94: Add an on_fatal_error Worker Hook
- [ ] R94.1 RED: subprocess-guarded integration test: fatal poll-loop death invokes on_fatal_error with the error before run() returns; a throwing hook is swallowed and does not mask the original failure
- [ ] R94.2 GREEN: add on_fatal_error to Worker->new; invoke before fatal-path shutdown at Worker.pm:568,589; log-and-ignore hook exceptions, to _worker.py:47,202-204 parity
- [ ] R94.3 REFACTOR: route the hook through the single fatal-path unwind point; comment cites finding 3
- [ ] R94.4 Verify: hook fires pre-return, throwing hook swallowed, original failure surfaces; prove -lj4 t green under memory guard

### Step R95: Provide a Real-History and Multi-History Replayer Surface
- [ ] R95.1 RED: replay test: multi-history JSON returns one result per history; mutated history yields Nondeterminism failure; from_json round-trips identically
- [ ] R95.2 GREEN: Test/WorkflowReplay.pm accepts real WorkflowHistory + from_json, batch-replays returning per-history results with per-history nondeterminism failure, to _replayer.py:110,138,166 parity
- [ ] R95.3 REFACTOR: reuse the R43 real nondeterminism check per history; comment cites finding 4 + resolved from-history direction
- [ ] R95.4 Verify: batch per-history results, mutated fails Nondeterminism, from_json round-trips; prove -lj4 t green under memory guard

### Step R96: Add an Activity Context-Aware Logger
- [ ] R96.1 RED: unit test: log_details yields the documented field set (activity id/type, attempt, namespace, task queue, workflow ids); xt POD check requires the wiring-pattern note (fails until present)
- [ ] R96.2 GREEN: expose the logging-detail accessor on Activity/Context.pm (no logging dependency) + POD documenting the caller-logger pattern, to activity.py:479-537 field parity
- [ ] R96.3 REFACTOR: build the detail hash once from Info; comment cites finding 6 + no-mandated-framework resolution
- [ ] R96.4 Verify: accessor yields documented fields, POD documents wiring; prove -lj4 t and xt green under memory guard

### Step R97: Document the Legacy Build-ID Worker-Versioning APIs as a Deliberate Deviation
- [ ] R97.1 RED: xt POD check asserts Client.pm POD names the three omitted build-id APIs + deployment replacement (fails while absent); unit test asserts deployment-versioning path is green
- [ ] R97.2 GREEN (doc-only): add the deliberate-deviation POD section to Client.pm naming the three RPCs and pointing to deployment versioning; do NOT implement them
- [ ] R97.3 REFACTOR: cross-link the note to the deployment-versioning POD; comment cites finding 5 + spec §0 surface deviation
- [ ] R97.4 Verify: POD names the three APIs + replacement, deployment-versioning test green, xt POD coverage green; prove -lj4 t green under memory guard
