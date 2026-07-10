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
- [x] R51.1 RED: guard in t/unit/runner_comments.t fails while the stale "pre-scheduled cancel" phrasing remains at Runner.pm:1188-1193
- [x] R51.2 GREEN: rewrite the :1188-1193 comment to the real _apply_cancel_workflow fallback mechanism post-R8-R10; fix the contradicting nexus arm comment
- [x] R51.3 REFACTOR: ensure the comment cites finding R3 and the fixed behavior
- [x] R51.4 Verify: guard passes plus reviewer sign-off in the commit message; prove -lj4 t green under the memory guard

### Step R40: Cover the Post-Cancel Paths in the Replay Suite
- [x] R40.1 RED: add t/replay/post_cancel_child_workflow.t, post_cancel_timer.t, post_cancel_local_activity.t in catch-and-cleanup and propagate shapes
- [x] R40.2 GREEN: no product code (behavior fixed by R8-R10); any failure is a real gap traced back to the cluster
- [x] R40.3 REFACTOR: header each file mapping it to finding T8 and its arm; keep the four-arm ledger visible
- [x] R40.4 Verify: four arms covered in both shapes (activity via R8-R10 repros); closed LAST in the cluster; prove -lj4 t green under the memory guard

## Phase P5: Cancellation Semantics

### Step R12+R52+R53: Cancellation-Type Test File
- [x] R12+R52+R53.1 RED: replay cancellation_types.t covers WAIT vs TRY_CANCEL regular activity, evict of wait-type LA, and double-cancel LA
- [x] R12+R52+R53.2 GREEN: honor WAIT_CANCELLATION_COMPLETED on the regular-activity arm, make evict cancel LAs unconditionally, add at-most-once LA cancel guard
- [x] R12+R52+R53.3 REFACTOR: share one wait-type helper across both activity arms; cite R7/L8/L10 + Python parity
- [x] R12+R52+R53.4 Verify: pending-until-resolution, TRY_CANCEL-unchanged, eviction-completes, exactly-one-cancel assertions pass; prove -lj4 t green

### Step R13: Keep Query and Update Responses on Failure Completions
- [x] R13.1 RED: replay failure_keeps_responses.t asserts query and update responses survive a same-activation failure; mutating commands dropped
- [x] R13.2 GREEN: partition @commands at Runner.pm:3054, retain handler responses, correct the false Python comment
- [x] R13.3 REFACTOR: extract is_handler_response_command predicate; cite R9 + Python source
- [x] R13.4 Verify: response-present and mutating-dropped assertions pass; prove -lj4 t green

### Step R14+R15: Route workflow_failure_exception_types and nondeterminism_as_workflow_fail to Live Runners
- [x] R14+R15.1 RED: unit dispatcher_failure_options.t asserts both options reach the live Runner; replay failure_exception_types.t asserts workflow vs task failure
- [x] R14+R15.2 GREEN: reroute both options from core's workflow-type field into the live Runner constructor at Worker.pm:459-460 / WorkflowDispatcher.pm:170-181
- [x] R14+R15.3 REFACTOR: name the plumbing keys once so live and replay share them; cite A1/ADJ2
- [x] R14+R15.4 Verify: unit-arrival and replay outcome assertions (listed-type + nondeterminism) pass; prove -lj4 t green

### Step R17: Settle Updates from Cancelled Handler Futures Without Croaking
- [x] R17.1 RED: replay evict_pending_update.t (no croak, eviction completes) + unit settle_update_states.t (done/failed/cancelled)
- [x] R17.2 GREEN: discriminate the cancelled future in _settle_update before ->result and settle per the eviction contract
- [x] R17.3 REFACTOR: factor a settle-core sub; embed the probe state table; cite L7
- [x] R17.4 Verify: no-croak eviction and three-state settle assertions pass; prove -lj4 t green

### Step R23+R50: Make the Shared Cancellation Future Survive wait_any (with Direct ChildCancellation Tests)
- [x] R23+R50.1 RED: cancellation.t wait_any-double-race then later-consumer-observes; new child_cancellation.t covers construction, observation, and the race
- [x] R23+R50.2 GREEN: cancelled() returns a per-call derived (or ->without_cancel) future in Cancellation.pm and Activity/ChildCancellation.pm
- [x] R23+R50.3 REFACTOR: share the derivation helper; add POD documenting the safe-to-race contract; cite R2/T2
- [x] R23+R50.4 Verify: both classes' second-consumer-observes assertions pass; prove -lj4 t and xt green

### Step R24: Enforce Read-Only Context and Writability Asserts Uniformly
- [x] R24.1 RED: replay query_readonly.t table-drives the four bypassing APIs raising the typed read-only error in query context; unchanged in writable context
- [x] R24.2 GREEN: add _assert_writable at the four sites and run query handlers in a read-only context that raises on command emission
- [x] R24.3 REFACTOR: table-drive the guard so new APIs inherit it; cite R8 + Python read-only parity
- [x] R24.4 Verify: each API raises in query context and works in writable context; prove -lj4 t green

### Step R20: Isolate Exceptions Per Entry in the Callback Drain Loop
- [x] R20.1 RED: unit callback.t enqueues a chunk with a dying middle entry; asserts later entries still run and the death is captured
- [x] R20.2 GREEN: wrap each per-entry continuation in its own eval at Core/Callback.pm:322-331,:463-467; log and continue
- [x] R20.3 REFACTOR: factor a guarded-invoke helper for both drain sites; cite L17
- [x] R20.4 Verify: all non-dying entries ran despite the middle death; prove -lj4 t green

## Phase P6: Workflow and Client Semantics

### Step R25: Send search_attributes and versioning_intent on Continue-as-New
- [x] R25.1 RED: replay continue_as_new_options.t asserts both fields present with values when set, proto defaults when omitted
- [x] R25.2 GREEN: carry both options into the ContinueAsNewWorkflowExecution command at Runner.pm:2933-2980 using confirmed proto field names
- [x] R25.3 REFACTOR: reuse the shared search-attribute encoder; cite R11 + proto path
- [x] R25.4 Verify: present-with-values and omitted-defaults assertions pass; prove -lj4 t green

### Step R26: Deliver Init Signals Before the Main Routine Starts
- [x] R26.1 RED: replay init_signal_ordering.t asserts an init-activation signal handler's side effect is visible to the main routine's prologue
- [x] R26.2 GREEN: apply same-activation signal jobs before the main routine's synchronous prologue at Runner.pm:2317-2319,:1709,:1716
- [x] R26.3 REFACTOR: make the signals-before-main job order explicit; cite R12 + ../sdk-python ordering
- [x] R26.4 Verify: handler-visible-to-prologue assertion passes and post-start signals still work; prove -lj4 t green

### Step R27+R38: Determinism-Guard Install Point and Override Accountability
- [x] R27+R38.1 RED: subprocess-guarded determinism_guard_load_order.t (pre-loaded workflow trips the guard) + unit determinism_guard.t (stock time/rand outside workflow context)
- [x] R27+R38.2 GREEN: install/arm the guard at Definition registration; keep overrides transparent passthroughs outside workflow context with a defined uninstall/permanence decision
- [x] R27+R38.3 REFACTOR: route R27 and R38 through one install point; document the override lifecycle in Worker POD; cite R13/A15
- [x] R27+R38.4 Verify: guard-trips-for-preloaded and stock-outside-context assertions pass; prove -lj4 t and xt green

### Step R29: Break the Start-Future Ownership Cycle in Handles
- [x] R29.1 RED: unit handle_start_cycle.t asserts DESTROY runs (weak-ref liveness) for ChildWorkflowHandle and NexusOperationHandle after refs drop
- [x] R29.2 GREEN: resolve start futures with a non-owning token (or weaken the back-reference) at Runner.pm:895-897 and the two handle classes
- [x] R29.3 REFACTOR: centralize any token-for-handle exchange; cite L5 and flag the same shape elsewhere
- [x] R29.4 Verify: both DESTROY-after-drop assertions pass and callers still get the handle; prove -lj4 t green

### Step R31: Honor Pending Futures from Custom Slot Suppliers
- [x] R31.1 RED: unit slot_supplier_pending.t asserts no permit while the reserve future is pending and the permit matches the resolved value
- [x] R31.2 GREEN: defer the permit for a pending reserve future in _resolve_permit at SlotSupplierRegistry.pm:102-117,:141-148
- [x] R31.3 REFACTOR: clearly name the pending-vs-resolved branch; cite L19 + shim reserve-timing note
- [x] R31.4 Verify: no-permit-while-pending and permit-matches-value assertions pass; prove -lj4 t green

### Step R32: Implement Nexus cancel_task
- [x] R32.1 RED: extend replay nexus.t to dispatch a task, deliver cancel_task, and assert the operation future is cancelled and ack_cancel fires
- [x] R32.2 GREEN: register running operations in %running and wire cancel_task to cancel the future and send ack_cancel at NexusDispatcher.pm:109,:93-98,:350-353
- [x] R32.3 REFACTOR: pair register/deregister across completion, failure, and cancel; cite L20
- [x] R32.4 Verify: cancel-and-ack assertions pass and a normal op still completes/deregisters; prove -lj4 t green

### Step R36: Complete the Workflow info() Surface
- [x] R36.1 RED: replay workflow_info.t asserts workflow_id, attempt, task_queue carry init-activation values; existing fields unchanged
- [x] R36.2 GREEN: populate the three fields from init data at Runner.pm:391-407 and correct the POD at Workflow.pm:470-471
- [x] R36.3 REFACTOR: source all info() fields from one init struct; cite A5 + Python info() field list
- [x] R36.4 Verify: three-fields assertion passes; xt POD green; prove -lj4 t and xt green

### Step R35: Validate Activity Options at the Call Site
- [x] R35.1 RED: replay activity_option_validation.t asserts typed error for no-timeout and unknown-key (both activity kinds); valid call succeeds
- [x] R35.2 GREEN: require a timeout and reject unknown keys with Temporalio::Exception::Argument at Runner.pm:449-511 and :562 onward
- [x] R35.3 REFACTOR: factor a shared known-keys + required-timeout validator (aligned with R44/R55); cite A2
- [x] R35.4 Verify: no-timeout-raises, unknown-key-raises, and valid-succeeds assertions pass by class; prove -lj4 t green

### Step R44: Unify Unknown-Option Strictness on the Client Surface
- [x] R44.1 RED: unit client_option_strictness.t sweeps public client methods asserting the typo raises the typed error; known keys accepted
- [x] R44.2 GREEN: reject unknown option keys at Client/WorkflowHandle.pm:56 via the shared validator (Temporalio::Exception::Argument)
- [x] R44.3 REFACTOR: extract one client-surface unknown-option validator aligned with R35; cite A10
- [x] R44.4 Verify: typo-raises sweep passes and known keys still pass; prove -lj4 t green

### Step R55: Raise Typed Errors for Missing Workflow-Context Arguments
- [x] R55.1 RED: replay workflow_arg_errors.t asserts Temporalio::Exception::Argument by class at Runner.pm:451-453 and :579-581
- [x] R55.2 GREEN: replace the plain string dies with the typed throw, reusing the R35 validator where the region overlaps
- [x] R55.3 REFACTOR: route both sites through the shared argument-validation helper; cite A14
- [x] R55.4 Verify: both sites raise catchable typed errors asserted by class; prove -lj4 t green

### Step R37: Wire or Reject start_workflow Extended Options
- [x] R37.1 RED: unit start_workflow_extended_options.t captures the request and asserts static_summary/static_details in user-metadata and versioning_override wired (or typed-reject)
- [x] R37.2 GREEN: stop deleting the three options at Client.pm:572-574; wire summary/details to user-metadata and versioning_override to its field, else raise the typed error
- [x] R37.3 REFACTOR: reuse the user-metadata encoding helper; cite A7 + Python encoding
- [x] R37.4 Verify: fields-in-request (or typed-reject) assertions pass; prove -lj4 t green + start_workflow.t skip_all offline

## Phase P7: Test Infrastructure and Tracing

### Step R33+R46+R47+R48: DevServer and Test-Helper Future-State Fixes
- [x] R33+R46+R47+R48.1 RED: unit tests in devserver_shutdown.t (shared with R3) + test_await_helpers.t force timeout/throw/wedge cases with the adapted future_semantics probe
- [x] R33+R46+R47+R48.2 GREEN: reap late completions (DevServer:174-187, Client:39-57), flag-after-success (DevServer:207-208), reachable diagnostics (DevServer:35-37, Worker:45-46), reachable retry (Client:43-51)
- [x] R33+R46+R47+R48.3 REFACTOR: factor the shared wait_any loser-reaper helper; comment each site with L26/T5/T6 and the Future 0.52 state
- [x] R33+R46+R47+R48.4 Verify: reaper observed, retryable shutdown, diagnostic text, connect retry; prove -lj4 t and xt green

### Step R34+R61: Remove the Ephemeral-Port Race and Fix the Net::EmptyPort Dependency Phase
- [x] R34+R61.1 RED: concurrent four-server integration test (skip_all offline) + emptyport_range unit probe + cpanfile dependency-audit assertion
- [x] R34+R61.2 GREEN: race-free port strategy at DevServer:109,:143; drop-or-rephase Net::EmptyPort in DevServer:12 and cpanfile
- [x] R34+R61.3 REFACTOR: comment the port site with T-flake and the chosen strategy; note R34/R61 coupling
- [x] R34+R61.4 Verify: no bind failure/cross-connect, updates.t flake gone, cpanfile phase matches uses; prove -lj4 t and xt green

### Step R49: Register Dev-Server Teardown in END Blocks
- [x] R49.1 RED: xt/devserver_end_teardown.t statically asserts END-block teardown in every DevServer-using integration file (fails now)
- [x] R49.2 GREEN: move/add END-block teardown to each flagged t/integration/*.t per updates.t:176-179
- [x] R49.3 REFACTOR: comment the xt probe with T9 and the DevServer:244-251 hazard
- [x] R49.4 Verify: xt probe passes; die no longer orphans CLI; prove -lj4 t and xt green

### Step R43: Make WorkflowReplay's Nondeterminism Claim True or Scoped
- [x] R43.1 RED: implemented -> t/replay/nondeterminism.t on mutated history; scoped -> xt grep probe for the overclaim
- [x] R43.2 GREEN: engage core replayer at WorkflowReplay:59-95, or scope README:545-552 and POD; record direction in commit
- [x] R43.3 REFACTOR: comment WorkflowReplay:59 with R14 and the chosen direction
- [x] R43.4 Verify: mutated-history error or grep finds no overclaim; prove -lj4 t and xt green

### Step R45: Revive the Dead Nexus Integration Test
- [x] R45.1 RED: perl -c on t/integration/nexus.t fails on with_worker and the API misuse (adapted: perl -c passes — the misuses are runtime-only — so the RED is the gated run dying at :74 with "Odd name/value argument for subroutine 'Temporalio::Client::connect'"; with_worker confirmed nonexistent tree-wide)
- [x] R45.2 GREEN: fix with_worker (:74-77), connect positionals (:90), iterator consumption (:103-108); keep skip_all offline
- [x] R45.3 REFACTOR: align with nearest working integration file; comment with T7
- [x] R45.4 Verify: perl -c passes offline, prove -l passes with server, skip_all offline; prove -lj4 t and xt green

### Step R22+R41+R42: Implement the OpenTelemetry TracingInterceptor and Point Its Tests at the Wired Behavior
- [x] R22+R41+R42.1 RED: rewrite t/unit/tracing.t on the fake-tracer scaffold to assert span creation per surface, header round-trip, R41 mutation note, R42 OTel-installed fixture (t/lib/FakeOTel.pm; 7 of 14 subtests failed against the delegation-only stub)
- [x] R22+R41+R42.2 GREEN: implement spans + header inject/extract at TracingInterceptor:205-233 matching Python contrib; correct POD at :286-290 (plus: RunWorkflow/CompleteWorkflow span names gain the Python-parity :{type} suffix; ActivityDispatcher threads `info` onto the ExecuteActivity input; new() defaults to a real OTel tracer when installed — the R42 fix)
- [x] R22+R41+R42.3 REFACTOR: extract span-naming/header-carrier helpers; comment with R1; note samples-perl R3 can lift
- [x] R22+R41+R42.4 Verify: spans/headers asserted, revert fails tests (the RED run), gated subtest passes with/without OTel (verified against a real OpenTelemetry 0.033 + SDK 0.028 side local::lib, headless and SDK-configured), POD matches (workflow-outbound spans documented as R71-pending); prove -lj4 t (159 files/734 tests) and xt (413) green

### Step R70: Convert Offline-Skipping Repro Guards to Replay Tests
- [x] R70.1 RED: new t/replay/<name>.t per convertible guard using the R8-R10 harness; each fails if the fix reverts (run LAST) (new: repro_cancel_wait_condition.t #5, repro_cancel_mid_update.t #8, repro_external_signal.t #2; #4 and both #10 guards already had offline twins)
- [x] R70.2 GREEN: move convertible assertions into replay tests; keep server-only guards with a why comment (deleted 6 converted integration guards; why-comments on repro_fd_signal/repro_local_activity/repro_nexus/repro_nexus_callback)
- [x] R70.3 REFACTOR: align new replay files with harness conventions; comment with T10 (offline twins annotated as the R70 replacements)
- [x] R70.4 Verify: offline suite fails on any reintroduced regression (mutation check: @conditions sweep disabled -> both cancel guards fail); server-only guards justified; prove -lj4 t and xt green

## Phase P8: Converter, POD, and Parity Edges

### Step R56-R59: Converter Batch
- [x] R56-R59.1 RED: converter_errors.t for poisoned failure converter, malformed UTF-8, empty-data json/plain; xt pod check for BinaryPlain/Json claim conditions
- [x] R56-R59.2 GREEN: wrap failure errors (Data:152-153,:182), check utf8::decode (JsonProtobuf:48), define empty-data outcome, fix POD (BinaryPlain:25-27 + Json)
- [x] R56-R59.3 REFACTOR: comment sites with L22/L23/ADJ1/L24; note R57/R68 shared probe
- [x] R56-R59.4 Verify: typed wrapper, UTF-8 raise, empty-data Python parity, POD maps to code; prove -lj4 t and xt green

### Step R64-R66: POD Pass
- [x] R64-R66.1 RED: xt grep probe for "arrives later"; xt kwarg-vs-POD cross-check for Worker->new and connect; list_workflows behavior test
- [x] R64-R66.2 GREEN: fix list_workflows POD (Client:275-281,:1109-1111); strip stale POD (Client:1010-1011, Worker:1060-1063, Activity:74-79); document all kwargs + connect options
- [x] R64-R66.3 REFACTOR: keep the xt cross-check general; comment with A9/A11/A12
- [x] R64-R66.4 Verify: grep returns nothing, xt cross-check passes, return type matches test; prove -lj4 t and xt green

### Step R54: Ship the Promised Workflow memo and search_attributes Readers
- [x] R54.1 RED: t/replay/workflow_memo_sa_readers.t reads both before and after an upsert (new WfDef::MemoSaReader fixture snapshots both readers around an upsert and returns them as the result; both subtests failed undefined-subroutine)
- [x] R54.2 GREEN: add memo and search_attributes readers in Workflow.pm/Runner.pm returning current values, Python-parity shapes (fresh copies of %memo_view / %search_attributes_view; NoRunner outside a body via _runner())
- [x] R54.3 REFACTOR: source readers from the upsert-written state; comment with A6 and archived spec lines (readers read the exact fields upsert_* writes; info() now delegates to them so the views cannot drift)
- [x] R54.4 Verify: initial then updated values returned; xt pod covers readers; prove -lj4 t and xt green (t: 159 files/733 tests incl. live integration; xt: 414 after adding Workflow.pm + Runner.pm POD entries)

### Step R60: Align Metric-Drop Behavior with Its Documentation
- [x] R60.1 RED: metric_meter_drop.t asserts documented unbound-record behavior and warn rate-limiting (4 subtests: create+record+free burst via the shim callbacks, buffer-until-bound white-box, both warn sites rate-limited; all 4 failed honestly)
- [x] R60.2 GREEN: chose buffer-until-bound (records buffer in %PENDING until the create binds; frees defer past the records drain so a create/record/free burst loses nothing); both warn sites go through _warn_rate_limited (one per site per 5s)
- [x] R60.3 REFACTOR: comments cite L28/R60 at every touched site; POD Threading section now states the never-dropped contract and the 5s warn rate limit, agreeing with the shim registry doc and the Callback.pm drain doc
- [x] R60.4 Verify: all 4 metric_meter_drop.t subtests green, existing metric_meter.t untouched-green; prove -lj4 t green (160 files, 737 tests, live integration) and prove -lj4 xt green (414, after rewording a comment that tripped the R65 arrives-later guard)

### Step R63: Accept the Spec-Promised Workflow Argument Forms in start_workflow
- [x] R63.1 RED: start_workflow_argforms.t covers the archived-spec §7.4 forms (type-name string regression, definition class name, :Run method ref), the shared signal_with_start path, and five unresolvable shapes; 4 of 5 subtests failed honestly pre-fix
- [x] R63.2 GREEN: Client `_workflow_name` accepts the definition-class and function-ref forms via the new single-sourced `Temporalio::Workflow::Definition::resolve_workflow_type` (coderef looked up by refaddr in the per-class %_DEFS registry); unresolvable forms (incl. a Definition subclass with no :Run) raise the typed Argument error pre-RPC; plain strings stay verbatim without loading the definition layer (lazy require only on ref forms)
- [x] R63.3 REFACTOR: Workflow.pm `_workflow_type_name` (start_child_workflow / continue_as_new) now delegates to the same resolver with a verbatim fallback; comments cite A8 and the archived v1 spec §7.4 promise; start_workflow POD documents the three forms; resolver documented in Definition.pm POD
- [x] R63.4 Verify: both forms resolve (CustomRun -> CustomWorkflow, Plain -> execute), string form unchanged; prove -lj4 t green (161 files, 742 tests, live integration) and prove -lj4 xt green (414)

### Step R67: Map and Validate query reject_condition
- [x] R67.1 RED: query_reject_condition.t covers the three Python-parity named values' enum mapping, raw-number pass-through and omitted-field regressions, and one invalid value raising the typed error pre-RPC; named-value and invalid subtests failed honestly pre-fix
- [x] R67.2 GREEN: %QUERY_REJECT_CONDITION map (none=>1, not_open=>2, not_completed_cleanly=>3, Python-parity per sdk-python common.py) wired into _root_query; raw proto numbers pass through; unknown names raise Temporalio::Exception::Argument before any RPC; POD lists the names
- [x] R67.3 REFACTOR: the map lives next to the proto-enum comment (enums/v1/query.proto) and validates through the shared _named_enum helper (renamed from _reapply_enum, now single-sourced across the reset and query maps); comments cite A13
- [x] R67.4 Verify: named values map, invalid raises, POD lists names; prove -lj4 t green (162 files, 746 tests, live integration) and prove -lj4 xt green (414)

### Step R68: Accept Non-Temporalio Causes in Exception Chaining
- [x] R68.1 RED: exception_cause_chaining.t chains a plain string die and a foreign object (adapted probe cause assertions); 4 subtests incl. wire encoding via the T-fail-4 wrapper; 3 of 4 failed honestly on the old Argument throw
- [x] R68.2 GREEN: accept any defined cause (store-as-is, Python __cause__ parity) by dropping the ADJUST isa-throw; as_string discriminates and chomps non-exception causes; exception.t's old rejection subtest repinned to the new contract
- [x] R68.3 REFACTOR: POD gains "The cause contract" section (accessor as-is, as_string rendering, T-fail-4 wire wrapping); ADJUST comment cites A16 and the shared probe_cause_mojibake.pl probe
- [x] R68.4 Verify: string die and foreign object survive as causes (identity preserved), POD states contract; prove -lj4 t green (163 files, 750 tests, live integration) and prove -lj4 xt green (414)

### Step R69: Close the Four Verified Cross-SDK Divergences
- [x] R69.1 RED: four tests: parity_backfills, parity_activity_priority_summary, parity_list_page_size, parity_execute_update_wait_for_stage (all four landed: commit 1 parity_backfills.t, honest RED on the singular kwarg; commit 2 parity_activity_priority_summary.t, honest RED on the unknown-key Argument; commit 3 parity_list_page_size.t, honest RED on the missing default; commit 4 parity_execute_update_wait_for_stage.t, honest RED on the clobbered caller value, WaitPolicy stage 3 vs the requested 2)
- [x] R69.2a GREEN (commit 1): add schedule backfills kwarg wired to proto (divergence per step-44 finding A17 is the kwarg FORM: Python `backfill` singular, _client.py:2675, vs shipped Ruby-style `backfills`, client.rb:684; create_schedule now accepts both wired to initial_patch.backfill_request, both-given raises Argument)
- [x] R69.2b GREEN (commit 2): add activity priority/summary options carried to the command (schedule_activity now takes priority, a Temporalio::Common::Priority, wired to ScheduleActivity.priority, and summary, wired to the WorkflowCommand user_metadata.summary Payload; Python parity _workflow_instance.py:3155-3183; local activities keep summary and stay priority-less, the proto has no LA priority field)
- [x] R69.2c GREEN (commit 3): send page-size defaults on list calls (list_workflows and list_schedules now default page_size to 1000 when the caller omits it, Python parity _client.py:1230 and :2732; the iterators already forwarded an explicit value, the gap was only the omitted-kwarg case; explicit values still win)
- [x] R69.2d GREEN (commit 4): stop execute_update overriding the caller's wait_for_stage (the default 'completed' now goes BEFORE %opts so an explicit caller value wins; omitted-kwarg default stays COMPLETED, Python parity _workflow.py:830, whose execute_update takes no wait_for_stage kwarg at all and hard-codes COMPLETED)
- [x] R69.3 REFACTOR: per-diff comment citing A17 and the checked Python behavior (all four diffs carry the A17 citation and the _client.py/_workflow_instance.py/_workflow.py anchors)
- [x] R69.4 Verify: one passing assertion per item, four separate commits; prove -lj4 t and xt green (commit 4: t 167 files/760 tests green, xt 414 green)

## Phase P9: Parity — Interceptor and High-Value Gaps

### Step R71: Wire and Invoke the Workflow-Outbound Interceptor Chain
- [x] R71.1 RED: replay test asserting outbound execute_activity/start_child_workflow interceptor mutations reach the emitted command; fails on unwired base (t/replay/interceptor_workflow_outbound.t, 3 of 4 subtests failed pre-wire; the no-interceptor control passed)
- [x] R71.2 GREEN: give WorkflowOutbound the eight methods, build the root outbound, fold interceptors, call inbound->init(outbound), route ops through the chain (Interceptor.pm gained start_nexus_operation/info + StartNexusOperation/Info inputs; new _RootWorkflowOutbound.pm; _RootWorkflowInbound captures init's outbound via on_init, Python _workflow_instance.py:392-398/2909-2910 semantics, interceptors wrap the outbound in their inbound init, so the fold is init-driven, last-listed wrapper outermost; Runner routes schedule_activity, schedule_local_activity, start_child_workflow, both signal arms, continue_as_new via a new Runner method Workflow.pm delegates to, start_nexus_operation, and info through the chain with _root-coderef inputs in the client kwargs shape)
- [x] R71.3 REFACTOR: extract outbound-chain construction into a helper; comment citing parity finding 1 / _interceptor.py:416-481 (Runner::_build_interceptor_chains builds both chains, cites the finding and both Python anchors; OTel seam notes in TracingInterceptor.pm updated, chain wired, the tracing outbound wrapper itself is a later pass)
- [x] R71.4 Verify: mutation-reaches-command assertions green; prove -lj4 t green under the memory guard (t: 168 files/764 tests green incl. live integration; xt: 416 green after adding the _RootWorkflowOutbound %TRUSTME entry and Runner continue_as_new POD)

### Step R72: Add the Activity-Outbound Interceptor and Wire ActivityInbound.init
- [x] R72.1 RED: unit test asserting an activity interceptor's outbound heartbeat override fires when the body calls heartbeat (t/unit/interceptor_activity_outbound.t: delegating override observes details and still reaches the recorder, swallowing override replaces the recording, info override observes the call with real info returned through the root, base still heartbeats through; failed pre-wire at compile, ActivityOutbound did not exist)
- [x] R72.2 GREEN: add ActivityOutbound (info, heartbeat), build root outbound and call inbound->init(outbound) (ActivityDispatcher.pm:152), route Context heartbeat/info through it (Interceptor.pm gained ActivityOutbound + a Heartbeat input, details ride the writable args field, Python's *details; new _RootActivityOutbound.pm; _RootActivityInbound captures init's outbound via on_init, mirroring R71; the dispatcher hands the finished chain to Activity::Context, whose heartbeat/info route through it when set — the fork-pool child context has no chain, a documented spec §0 deviation vs Python's parent-side register_heartbeater)
- [x] R72.3 REFACTOR: share the fold-over-root helper with R71; comment citing parity finding 2 / _interceptor.py:135-156 (new shared Temporalio::Worker::Interceptor::build_chains does the init-capture fold for both sides; Runner::_build_interceptor_chains now delegates to it; comments cite finding 2, _interceptor.py:135-156, and _activity.py:709-713/813-818)
- [x] R72.4 Verify: override-fires assertion green; prove -lj4 t green under the memory guard (t: 169 files/768 tests green incl. live integration; xt: 418 green after the _RootActivityOutbound %TRUSTME entry and build_chains POD)

### Step R73: Add the Nexus Operation Inbound Interceptor Role
- [x] R73.1 RED: unit test asserting a nexus-start interceptor override runs before the handler body (and cancel override wraps the handler) (t/unit/interceptor_nexus_inbound.t: two spies assert A:start/B:start before handler:traced with the result flowing back, a cancel override's before/after brackets the fake client's backing-workflow cancel, and the no-interceptor base runs the handler directly with the same result; failed pre-wire at compile, NexusOperationInbound did not exist)
- [x] R73.2 GREEN: add intercept_nexus_operation and NexusOperationInbound (start/cancel), fold interceptors over a handler-running root in NexusDispatcher.pm:196,257 (Interceptor.pm gained the NexusOperationInbound base, the intercept_nexus_operation hook, ExecuteNexusOperationStart/Cancel inputs, and build_nexus_operation_inbound; new _RootNexusOperationInbound.pm runs the handler via the input's _root coderef, no init/outbound side since Python has none; _handle_start dispatches through the chain with ctx + input riding writable args and the dynamically-scoped Nexus context inside the root closure, _handle_cancel_operation now builds a CancelOperationContext and routes the backing-workflow cancel through the chain; Worker.pm threads $all_interceptors to the dispatcher)
- [x] R73.3 REFACTOR: unify the nexus fold with the R71/R72 helper; comment citing parity finding 3 / _interceptor.py:66-78,500-528 (the three per-kind builders now delegate to one shared _fold_inbound($interceptors, $root, $hook, $inbound_class); comments cite finding 3, _interceptor.py:66-78,500-528, and _nexus.py:657-675)
- [x] R73.4 Verify: override-before-handler assertion green; prove -lj4 t green under the memory guard (t: 170 files/771 tests green incl. live integration; xt: 420 green after the _RootNexusOperationInbound %TRUSTME entry and the NexusOperationInbound/builder POD)

### Step R74: Carry ApplicationError next_retry_delay Through Exception and Failure Proto
- [x] R74.1 RED: unit test round-tripping next_retry_delay through to_failure/from_failure and asserting the proto field is set (t/unit/application_error_next_retry_delay.t: 5.5s survives the round-trip, on-wire Duration is seconds=5/nanos=500000000, an ApplicationError without the field leaves the proto field unset and reads back undef; failed pre-wire, ApplicationError had no next_retry_delay method)
- [x] R74.2 GREEN: accept next_retry_delay on ApplicationError (Application.pm:11-14) and map it to/from ApplicationFailureInfo.next_retry_delay (Failure.pm:231-240,251-261) (new `field $next_retry_delay :param = undef` + accessor, seconds Perl-side like every other SDK duration; to_failure writes the Duration only when truthy, matching Python's `if error.next_retry_delay:` at _failure_converter.py:160-163, so undef AND 0 stay off the wire; from_failure reads it back as fractional seconds, undef when absent — a deliberate deviation from Python's unconditional ToTimedelta(), which manufactures timedelta(0) for unset)
- [x] R74.3 REFACTOR: centralize Duration<->seconds conversion; comment citing parity finding 1 / message.proto:27 (_duration_from_seconds/_seconds_from_duration subs in Failure.pm next to the category maps, both write and read paths use them; comment cites finding 1, message.proto:27, and _failure_converter.py:160-162,340; the pre-existing per-module _duration copies in RetryPolicy/Schedule/Commands are untouched, out of step scope)
- [x] R74.4 Verify: survives round-trip and appears in proto field; prove -lj4 t green under the memory guard (t: 171 files/774 tests green incl. live integration; xt: 420 green, next_retry_delay POD added to Application.pm and the seconds-crossing note to Failure.pm DESCRIPTION)

### Step R75: Support encode_common_attributes on the Failure Converter
- [x] R75.1 RED: test with encode_common_attributes on + marker codec asserting on-wire message "Encoded failure" and codec-tagged encoded_attributes, and from_failure recovery (t/unit/failure_encode_common_attributes.t: XOR-codec relocation via Converter::Data, per-level cause relocation matching Python's recursive to_failure, no-codec json/plain payload, flag-off cleartext; failed pre-wire with "Unrecognised parameters ... encode_common_attributes")
- [x] R75.2 GREEN: accept encode_common_attributes; to_failure relocates message/stack_trace into encoded_attributes, from_failure restores (Failure.pm) (new `field $encode_common_attributes :param = 0`; to_failure builds the {message, stack_trace} payload via the payload converter then leaves the sentinel + empty trace, per _failure_converter.py:119-127; from_failure restores unconditionally (field-presence check, not the flag, per :312-327), swallowing decode errors, before %common/_message read the proto)
- [x] R75.3 REFACTOR: name the "Encoded failure" sentinel constant; comment citing parity finding 2 / _failure_converter.py:312-327 ($ENCODED_FAILURE_MESSAGE file-scoped next to the enum maps; comments cite finding 2 and the Python lines; POD documents the constructor param as the DefaultFailureConverterWithEncodedAttributes equivalent)
- [x] R75.4 Verify: on-wire encoded + recovery assertions green; prove -lj4 t green under the memory guard (t: 172 files/778 tests green incl. live integration; xt: 420 green; Data.pm:99-102 codec transform of encoded_attributes confirmed by the binary/xor-test tag assertion)

### Step R76: Expose Activity Cancellation Details and Reason
- [x] R76.1 RED: unit test delivering WORKER_SHUTDOWN and PAUSED cancels and asserting the context reports the matching reason and details (t/unit/activity_cancellation_details.t: park-on-cancel body observes reason name + the six boolean causes post-wake, package-fn identity, un-cancelled and holderless contexts report undef; all four subtests failed honestly pre-fix on the missing cancellation_details method)
- [x] R76.2 GREEN: capture Cancel reason + ActivityCancellationDetails (ActivityDispatcher.pm:105-113) and add a cancellation_details accessor on Context.pm (new Temporalio::Activity::CancellationDetails value class with from_proto mirroring activity.py:180-191; the dispatcher registers a set-on-cancel holder shared by reference with the Context, Python's _ActivityCancellationDetailsHolder shape, and _handle_cancel fills it BEFORE firing the token per _activity.py:221-226; reason rides as the enum NAME, a deliberate addition over Python which logs-and-drops it; Temporalio::Activity::cancellation_details() package fn added per activity.py:315-317)
- [x] R76.3 REFACTOR: fix Context POD conflating server-cancel with worker-shutdown; comment citing worker finding 2 / _activity.py:221-226 (field comment + =head2 cancellation now list all six causes and point to cancellation_details; both cite R76, worker finding 2 / activity+conversion finding 3, and _activity.py:221-226; fork-pool child's undef documented as a spec section 0 deviation)
- [x] R76.4 Verify: reason/details assertions green; prove -lj4 t and xt green under the memory guard (t: 173 files/782 tests green incl. live integration; xt: 422 green with the new module's POD)

### Step R77: Add workflow.uuid4 Deterministic UUID
- [x] R77.1 RED: replay test asserting uuid4() is a valid v4, stable across replay, differs from a second call, and is seeded from the activation randomness seed (t/replay/workflow_uuid4.t + WfDef::UuidCaller fixture; pre-fix failure confirmed as "Undefined subroutine &Temporalio::Workflow::uuid4")
- [x] R77.2 GREEN: add Workflow::uuid4 returning a v4 UUID from the workflow deterministic RNG (Workflow.pm) (four ISAAC irand draws packed big-endian = Python's getrandbits(16*8).to_bytes(16,"big"); version nibble forced to 4, variant to RFC 4122 10xx per uuid.UUID(version=4); canonical lowercase string like Client::_new_uuid)
- [x] R77.3 REFACTOR: reuse the existing deterministic RNG; comment citing in-workflow finding 1 / _context.py:866 (uuid4 draws from _runner()->random, the same generator random() returns, so it re-seeds with UpdateRandomSeed; comment also notes the T-det-4 self-exemption holds since no builtin is touched; =head2 uuid4 POD added)
- [x] R77.4 Verify: stability/uniqueness/seed assertions green; prove -lj4 t and xt green under the memory guard (t: 174 files/786 tests green incl. live integration; xt: 422 green)

### Step R78: Carry a Summary on Timers, sleep, and wait_condition Timeouts
- [x] R78.1 RED: replay test asserting StartTimer carries the user-metadata summary when passed (sleep/start_timer/wait_condition) and none when omitted (t/replay/timer_summary.t + WfDef::TimerSummary fixture; pre-fix failure confirmed as "Too many arguments for subroutine 'Temporalio::Workflow::sleep'" and a summary-less StartTimer on the wait_condition arm)
- [x] R78.2 GREEN: sleep/start_timer accept summary, wait_condition accepts timeout_summary, Runner emits StartTimer user-metadata (Workflow.pm sleep/start_timer take %opts; Runner start_timer converts summary up front and passes it to the command builder; wait_condition threads timeout_summary to its backing timer)
- [x] R78.3 REFACTOR: reuse the local-activity user-metadata summary builder; comment citing in-workflow finding 2 / _context.py:878,894 (extracted the shared Commands::_user_metadata helper now used by the activity, LA, nexus, and timer builders; POD updated in Workflow.pm/Runner.pm/Commands.pm)
- [x] R78.4 Verify: summary-present/absent assertions green; prove -lj4 t green under the memory guard (t: 175 files/790 tests green incl. live integration; xt: 422 green)

### Step R79: Expose Per-Activation Workflow Info Accessors
- [x] R79.1 RED: replay test driving an activation with history_length, history_size_bytes, build_id, continue_as_new_suggested and asserting each accessor returns the delivered (and updated) value (t/replay/workflow_activation_info.t + WfDef::ActivationInfoProbe fixture whose :Run snapshots the four accessors once per probe signal, so snapshot N carries activation N's values; a defaults subtest asserts field-less activations yield 0/0/''/false incl. the Python empty-string build_id; pre-fix failure confirmed honest via push_activation_completion: "Undefined subroutine &Temporalio::Workflow::get_current_history_length"; the probe had to move from the :Signal handler into :Run because a sync handler's die is swallowed by the untracked ready-but-failed handler future)
- [x] R79.2 GREEN: capture the four per-activation fields and expose get_current_history_length/size, get_current_build_id, is_continue_as_new_suggested (Runner.pm) (captured at the top of process_activation next to is_replaying/timestamp, build_id from deployment_version_for_current_task->build_id else '' per _workflow_instance.py:1195-1198; Runner methods plus Temporalio::Workflow package delegators, the same surface shape as is_replaying/random)
- [x] R79.3 REFACTOR: store the four fields in one per-activation struct updated at the boundary; comment citing in-workflow finding 3 / _context.py:140-185 (one %activation_info field hash assigned wholesale at the boundary; comments cite in-workflow finding 3, _context.py:140-185, and _workflow_instance.py:427-429; the Workflow.pm delegator comment documents the methods-on-Info -> package-functions spec section 0 surface deviation; POD added in Workflow.pm and Runner.pm, info()'s POD now points at the live readers)
- [x] R79.4 Verify: per-activation accessor assertions green; prove -lj4 t and xt green under the memory guard (t: 176 files/792 tests green incl. live integration; xt: 422 green after adding the four Runner =head2 entries pod-coverage demanded)

### Step R80: Add the max_concurrent_nexus_tasks Worker Kwarg
- [x] R80.1 RED: unit test asserting max_concurrent_nexus_tasks => N packs a FixedSize nexus supplier of N, unset keeps 100, and alongside tuner throws mutual-exclusion (t/unit/worker_max_concurrent_nexus_tasks.t via the P0.10 debug_worker_options echo; the mutual-exclusion subtest pins the "mutually exclusive" message so the unrecognised-parameter fallback cannot fake a pass; honest RED on subtests 1 and 3)
- [x] R80.2 GREEN: accept the kwarg (Worker.pm:60-62), feed the synthesized fixed tuner (Worker.pm:300,416), add to mutual-exclusion set (Worker.pm:959-961) (field default 100 beside its three siblings; _slot_supplier_options fallback now passes it as nexus_task_slots; @SLOT_KWARGS gained the fourth entry; POD item added and the tuner item now says "four")
- [x] R80.3 REFACTOR: fold into the existing max_concurrent_* handling; comment citing worker finding 1 / _worker.py:129-133 (implementation already lives inside the sibling handling; field comment cites worker finding 1 and the verified anchors _worker.py:118,:545-563, noting the plan's :129-133 drift)
- [x] R80.4 Verify: supplier-packing and mutual-exclusion assertions green; prove -lj4 t green under the memory guard (t: 177 files/795 tests PASS incl. live integration; xt: 422 PASS)

### Step R81: Add fairness_key and fairness_weight to Priority
- [x] R81.1 RED: unit test asserting to_proto sets priority_key, fairness_key, and fairness_weight (and leaves the latter two unset when absent) (t/unit/priority_fairness.t; the unset subtest leans on the pure-Perl proto accessors returning undef for never-set fields; honest RED confirmed as "Unrecognised parameters ... fairness_weight, fairness_key")
- [x] R81.2 GREEN: accept fairness_key (string) and fairness_weight (float) and encode both into Priority (Common/Priority.pm) (two new :param fields + readers; to_proto sets each `if defined`, matching Python's not-None guards in common.py:1212-1220)
- [x] R81.3 REFACTOR: validate fairness_weight type at construction as Python does; comment citing schedule/runtime finding 3 / message.proto:344,354 (ADJUST guard throws Temporalio::Exception::Argument on non-numeric weight, test-driven; comment notes Python's __post_init__ only guards priority_key and its fairness_weight enforcement lands via the typed proto setter, so the construction-time check is the Perl equivalent; POD updated for both params/accessors)
- [x] R81.4 Verify: three-field to_proto assertion green; prove -lj4 t green under the memory guard (t: 178 files/798 tests PASS incl. live integration; xt: 422 PASS)

### Step R82: Encode static_summary and static_details on the Schedule Action
- [x] R82.1 RED: request-capture/replay test asserting static_summary and static_details appear as encoded payloads in the emitted NewWorkflowExecutionInfo.user_metadata (none when absent) (t/unit/schedule_action_user_metadata.t, the schedule_request.t rpc-mock capture pattern; honest RED as `Unrecognised parameters ... static_summary, static_details`)
- [x] R82.2 GREEN: StartWorkflow accepts static_summary/static_details (Action.pm:28-39) and _to_proto encodes them into user_metadata (Action.pm:73-124) (two :param fields + readers; _to_proto sets user_metadata only when either is defined, mirroring Client.pm's R37 guard)
- [x] R82.3 REFACTOR: reuse the R37 user-metadata payload builder; comment citing schedule/runtime finding 1 / _schedule.py:551-552 (GREEN reused Converter::Data->encode_user_metadata from the start: string encodes to a single Payload, pre-encoded Payload passes through; POD updated for params/accessors)
- [x] R82.4 Verify: user_metadata payload assertions green; prove -lj4 t green under the memory guard (t: 179 files/800 tests PASS incl. live integration; xt: 422 PASS)

## Phase P10: Parity — Medium and Low

### Step R83: Expose a User-Facing Metric Meter in Workflow, Activity, and Nexus Context
- [x] R83.1 RED: replay + unit tests: workflow counter emits live and is suppressed on replay; activity + nexus counters reach a test buffer
- [x] R83.2 GREEN: add emission surface to Runtime/MetricMeter.pm; expose metric_meter on activity/workflow/nexus contexts (workflow no-ops on replay), to Python parity
- [x] R83.3 REFACTOR: share one instrument wrapper across the three contexts; comment cites parity finding 6 + replay suppression
- [x] R83.4 Verify: live emit, replay suppress, activity + nexus emit; prove -lj4 t green under memory guard (t: 181 files/808 tests PASS incl. live integration + a core-FFI e2e through a custom sink; xt: 422 PASS)

### Step R84: Provide Worker-Shutdown Detection Inside Activities
- [x] R84.1 RED: unit test: worker shutdown flips is_worker_shutdown and resolves the shutdown future; a plain cancel does not (t/unit/activity_worker_shutdown.t, the activity_cancellation_details.t dispatcher-seam pattern; honest RED as `Can't locate object method "notify_shutdown"/"is_worker_shutdown"`; 4 subtests incl. notify-before-start and the no-event fork-pool degradation)
- [x] R84.2 GREEN: add distinct worker-shutdown event/future to Activity/Context.pm:28-30; fire it at shutdown-begin, to activity.py:400-438 parity (new Temporalio::Common::Event — Python's _CompositeEvent shape, consumer-safe wait futures via CancellationFuture; dispatcher owns one shared event + notify_shutdown, injects it into every async context; Worker._initiate_shutdown_once notifies right after worker_initiate_shutdown, before graceful-period cancels, matching _worker.py:840-850; package fns Temporalio::Activity::is_worker_shutdown/wait_for_worker_shutdown)
- [x] R84.3 REFACTOR: name the event/future per Python; comment cites finding 4 + shutdown-vs-cancel (naming matched Python from the start: is_worker_shutdown / wait_for_worker_shutdown / notify_shutdown / worker_shutdown_event; comments cite finding 4 + the shutdown-vs-cancel distinction; the flip mechanism lives in Common::Event for R89 nexus reuse)
- [x] R84.4 Verify: shutdown observed distinctly from cancel; prove -lj4 t green under memory guard (t: 182 files/812 tests PASS incl. live integration; xt: 424 PASS)

### Step R85: Complete Activity Info with priority and retry_policy
- [x] R85.1 RED: unit test: start job with retry_policy + priority surfaces both on activity Info; neither present yields empty without error (t/unit/activity_info_priority_retry.t, 3 subtests, honest RED on both missing fields)
- [x] R85.2 GREEN: populate priority and retry_policy in Worker/ActivityDispatcher.pm:320-341, Python activity.py:130-136 naming (_build_info passes both through as their proto sub-messages, undef when the start job omits them; proto field names already match Python's Priority/RetryPolicy)
- [x] R85.3 REFACTOR: reuse existing priority/retry mappers; comment cites finding 5 (mappers NOT reusable: Common::Priority/Common::RetryPolicy are to_proto-only `feature class` objects, and Storable cannot freeze class objects across the sync-activity fork pool (proven by probe); the finding-5 comment in _build_info documents both facts; Context.pm info docs updated)
- [x] R85.4 Verify: both fields surface when set and stay absent when omitted; prove -lj4 t green under memory guard (t: 183 files/815 tests PASS incl. live integration; xt: 424 PASS)

### Step R86: Support Runtime Signal, Query, and Update Handler Registration
- [x] R86.1 RED: replay test: runtime-set signal handler runs; a buffered pre-registration signal drains on registration; getters return installed handlers (t/replay/runtime_handler_registration.t, 3 subtests over new WfDef::RuntimeHandlerRegistrar/RuntimeDynamicRegistrar/RuntimeHandlerGetters fixtures; honest RED as "Can't locate class method set_signal_handler")
- [x] R86.2 GREEN: add set_*_handler/get_*_handler to Workflow.pm/Workflow/Runner.pm with buffered-drain, to _workflow_ops.py:833-985 parity (all 12 Python functions incl. the dynamic variants, callable as package fns or class methods; named signal install drains that name's buffer, dynamic install drains ALL by arrival stamp; setters _assert_writable; update setter carries the validator kwarg and replaces wholesale like Python's fresh _UpdateDefinition)
- [x] R86.3 REFACTOR: unify compile-time and runtime handler tables behind one lookup; comment cites finding 4 + buffered drain (Runner's _handlers seeds per-instance descriptor tables {code,is_method} from _workflow_defs — Python's self._signals = dict(defn.signals) — and every resolver/dispatcher/known-names/validator site reads them via _invoke_handler/_handler_code; getters bind attribute methods to the instance like Python's bind_fn)
- [x] R86.4 Verify: runtime handler runs, buffered signal drains, getters work; prove -lj4 t green under memory guard (t: 184 files/818 tests PASS incl. live integration; xt: 424 PASS)

### Step R87: Honor Per-Handler HandlerUnfinishedPolicy
- [x] R87.1 RED: replay test: in-flight ABANDON update handler completes with no warning; default policy still warns; signal honors the option (t/replay/handler_unfinished_policy.t, 5 subtests over new WfDef::AbandonHandlers/ReturningSignaler fixtures + the existing ReturningUpdater default control; honest RED as "Unknown :Update option 'unfinished_policy'")
- [x] R87.2 GREEN: parse unfinished_policy in Workflow/Attributes.pm; consult it at the warn-and-complete site, to _handlers.py:36 parity (the audit's Workflow.pm:418-421 warn site now lives in Runner.pm's _build_completion; :Signal/:Update accept 'unfinished_policy=WARN_AND_ABANDON|ABANDON' — :Query rejects it like Python's query(); bad values rejected with the valid choices; Definition.pm records explicit policies in a sparse unfinished_policies registry bucket)
- [x] R87.3 REFACTOR: thread policy through the handler descriptor; comment cites finding 5 + default-warn/opt-out (satisfied by construction: the R86 unified-table descriptors carry unfinished_policy — default WARN_AND_ABANDON at seed time — %in_progress_handlers entries became {future,kind,name,unfinished_policy} records mirroring Python's HandlerExecution, and the completion warning filters WARN_AND_ABANDON only and names the unfinished handlers; runtime set_*_handler installs get the default since Python's setters take no policy)
- [x] R87.4 Verify: ABANDON no warning, default warns, signal honors policy; prove -lj4 t green under memory guard (t: 185 files/823 tests PASS incl. live integration; xt: 424 PASS)

### Step R88: Expose Last-Completion-Result and Last-Failure
- [x] R88.1 RED: replay test: seeded last-completion-result decodes via has_/get_last_completion_result; seeded last_failure types via get_last_failure; absent fields report false/undef (t/replay/last_completion_result.t, 3 subtests over new WfDef::LastRunReader fixture; honest RED as `Can't locate object method "has_last_completion_result"`)
- [x] R88.2 GREEN: capture and surface the carry-over fields from Workflow/Runner.pm, exposed on Workflow.pm, to _context.py:675,688,696 parity (_apply_initialize captures the raw last_completion_result Payloads + continued_failure; Runner workflow_has_last_completion_result / workflow_last_completion_result($type_hint) / workflow_last_failure mirror _workflow_instance.py:1837-1864 incl. the multi-payload warn+undef; Workflow.pm has_/get_last_completion_result + get_last_failure callable as package fns or class methods, type hint forwarded to from_payload)
- [x] R88.3 REFACTOR: decode lazily on first access; comment cites finding 7 (satisfied by construction: nothing decodes at init, the failure conversion caches on first access, the result decodes per call because the type hint can differ between calls like Python; finding-7 comments at the capture site, the reader block, and the field declarations)
- [x] R88.4 Verify: result decodes, failure types, absent reports false/undef; prove -lj4 t green under memory guard (t: 186 files/826 tests PASS incl. live integration; xt: 424 PASS)

### Step R89: Restore Dropped Nexus Handler-Context Capabilities
- [x] R89.1 RED: unit test: dispatched nexus op has OperationInfo->namespace = worker namespace; is_worker_shutdown flips true on dispatcher drain and waiters resolve (t/unit/nexus_context_capabilities.t + NexusDef::ContextCaps fixture, 5 subtests: namespace via ctx AND module helper, flip + parked waiter resolve, sync variant post-flip, sync-variant timeout false, outside-operation raise contract; honest RED on missing namespace param + undefined waiters)
- [x] R89.2 GREEN: add namespace to OperationInfo (Nexus/OperationContext.pm:18-28); add wait_for_worker_shutdown/_sync and set the shutdown flag in Nexus.pm, to _operation_context.py:82-147 parity (OperationInfo->namespace + worker_shutdown_event on all three contexts, dispatcher-injected like Python worker/_nexus.py:258-266,398-405; NexusDispatcher owns a Common::Event + notify_shutdown that flips $IS_WORKER_SHUTDOWN THEN sets the event so synchronously-resumed waiters read the flipped flag; Worker.pm keeps the nexus dispatcher and notifies it in _initiate_shutdown_once alongside the R84 activity call, and passes namespace => $client->namespace; is_worker_shutdown prefers the context event, falls back to the package flag, never raises; wait_for_worker_shutdown_sync($timeout) re-enters the IO::Async loop, true on shutdown / false on timeout)
- [x] R89.3 REFACTOR: share the shutdown-flip with R84 if adjacent; comment cites nexus finding 4 (satisfied by construction: the dispatcher reuses Temporalio::Common::Event with ActivityDispatcher's exact notify_shutdown pattern; nexus-finding-4 comments at Nexus.pm, the dispatcher event/notify_shutdown, the context fields, and the Worker.pm notify site)
- [x] R89.4 Verify: namespace matches, shutdown flips on drain, waiters resolve; prove -lj4 t green under memory guard (t: 187 files/831 tests PASS incl. live integration; xt: 424 PASS)

### Step R90: Implement Lazy Client Connections
- [x] R90.1 RED: subprocess-guarded integration test: lazy connect to an unreachable target succeeds; connect attempted only on first RPC; eager path unchanged (t/integration/lazy_client.t, two guarded scenarios: 127.0.0.1:1 eager-fails-at-construct / lazy-constructs / failure-surfaces-on-first-RPC, plus a live dev-server scenario where two concurrent first RPCs succeed sharing the deferred connect; honest RED on the v0.1 Argument throw in both scenarios; the dev-server child wraps post-start work in an eval-with-shutdown because a child that dies with the server up orphans the CLI holding prove's TAP pipe, wedging prove — hit on this file's own RED run)
- [x] R90.2 GREEN: remove the stale throw at Client.pm:817,829-831; defer connect to first RPC when lazy, to _client.py:151,205-207 parity (the core connect + Bridge-to-RpcError mapping moved into a $do_connect closure; eager awaits it inside connect() unchanged, lazy hands it to Connection as connect =>; _rpc_call resolves the pointer via await $connection->connected_ptr; the closure must ANCHOR @keep explicitly — it only captures what it references, and $options_record points into @keep, so the lazy path read freed buffers ("Invalid options: relative URL without a base") until the anchor)
- [x] R90.3 REFACTOR: once-init guard so concurrent first RPCs share one connect; comment cites finding 3 + removes stale v0.1 message (Connection.pm connected_ptr: $connect_future once-init shared by concurrent callers, cleared on failure so the next RPC retries like Python's lock-guarded re-check, close-mid-connect frees the arriving pointer; pre-connect ptr()/update_api_key raise Runtime — ptr() is what stops a worker on an unconnected lazy client, matching Python's RuntimeError; deterministic pins in t/unit/lazy_connection.t, 5 subtests over a controllable fake connect; finding-3 comments at Client.pm connect/_rpc_call and Connection.pm; R66's reject-documenting POD updated to the implemented behavior in Client.pm DESCRIPTION + =item lazy and Connection.pm)
- [x] R90.4 Verify: lazy construct ok, connect on first RPC, eager unchanged; prove -lj4 t green under memory guard (t: 189 files/838 tests PASS incl. live integration; xt: 425 PASS)

### Step R91: Expose Raw Service Clients on the Client
- [x] R91.1 RED: subprocess-guarded integration test (skip_all offline): operator-service RPC forms/sends via the raw handle; workflow-service raw RPC round-trips (t/integration/raw_service_client.t, one guarded dev-server scenario: workflow_service GetSystemInfo round-trips typed; operator_service AddSearchAttributes -> ListSearchAttributes shows the new Keyword attribute -> RemoveSearchAttributes deletes it; cross-service isolation pinned via can(); honest RED on the missing accessors)
- [x] R91.2 GREEN: expose a low-level WorkflowService/OperatorService handle in Client/Connection.pm + workflow_service/operator_service accessors on Client.pm, to _client.py:307-322 parity (the _rpc_call funnel body moved to Connection::rpc_call, matching Python where the rpc call is the service client's; Client::_rpc_call is now a thin delegator flipping retry default to 1 while Connection::rpc_call defaults retry 0, Python's raw-service retry=False; new Temporalio::Client::{WorkflowService,OperatorService} handle classes, one class per file per the F::AA lesson, each a $connection wrapper with a generic call(); Core/Proto.pm now also parses temporal/api/operatorservice/v1/*.proto as roots so the operator messages + descriptor exist)
- [x] R91.3 REFACTOR: generate the RPC method map from proto service descriptors; comment cites finding 1 (Temporalio::Client::RawService::install_rpc_methods reads the Protobuf::Schema service descriptor and installs one snake_case method per rpc (117 workflow, 12 operator) passing the CamelCase name the c-bridge dispatches on plus the descriptor-resolved response_class; finding-1 comments at RawService.pm, both handle files, Connection::rpc_call, and Client accessors; deterministic pins in t/unit/raw_service.t: full descriptor-vs-can() sweep both services, wrapper arg passthrough over a fake connection, snake_case cases, unknown-service throw)
- [x] R91.4 Verify: operator RPC forms/sends, workflow raw RPC round-trips; prove -lj4 t green under memory guard (t: 191 files/844 tests PASS incl. the live add/list/remove; xt: 432 PASS)

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
