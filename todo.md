# sdk-perl Issue-Closeout Todo (I1-I14, I18)

Checkbox tracker mirroring `plan.md`. Each step closes one GitHub issue with one green commit (`Closes #N`).
The R1-R97 cycle is archived at `.ai-sessions/r1-r97-remediation/`.

## Section 1: Silent-Failure Correctness Bugs

### Step I2: Fail the Workflow Task When a Sync :Signal Handler Dies
- [x] 1. RED: fixture WfDef/DyingSignal.pm + replay/signal_handler_die.t; a dying sync signal handler currently produces a normal completion (fails)
- [x] 2. Verify the Python signal-handler-raises contract; record file:line in test comments
- [x] 3. GREEN: track/funnel the failed sync-signal Future into the R11 failed-WFT sink in _dispatch_signal (Runner.pm:3164)
- [x] 4. RED: WfDef/DyingAsyncSignal.pm case asserting an async dying signal also fails the WFT
- [x] 5. GREEN: wire the async path if red; else record it already passes
- [x] 6. REFACTOR: one shared failure sink for both signal arms
- [x] 7. Docs: correct the signal-failure contract comment/POD
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #2"

### Step I3: Unwind Worker::run on a Fatal Poll-Loop Death
- [x] 1. RED: unit/fatal_poll_unwind.t (synthetic loop futures) + subprocess-guarded integration/fatal_poll_unwind.t; gather blocks on first failure today
- [x] 2. Verify Python worker/_worker.py:812,846-848 (FIRST_EXCEPTION + drain_poll_queue); record in comments
- [x] 3. GREEN: extract the gather; replace wait_all (Worker.pm:615) with a first-failure race; on fatal path initiate shutdown + drain polls before _finalize_and_free (:960), preserving on_fatal_error (:631) ordering
- [x] 4. RED: healthy-path assertion (no failure -> gather returns only after all loops drain)
- [x] 5. GREEN: combinator waits all on the clean path, returns on first failure
- [x] 6. REFACTOR: run() reads gather -> (fatal? initiate+drain) -> finalize via _await_loops_then_drain
- [x] 7. Docs: correct the run() contract comment (:565-608)
- [x] 8. Verify: prove -lj4 t green; commit "Closes #3"

### Step I1: Settle an Evicted Async :Update Parked on wait_condition Without Croaking
- [x] 1. RED: fixture WfDef/UpdateParker.pm + replay/evict_pending_update_wait_condition.t; the "already failed" croak fires, no eviction completion today
- [x] 2. Verify the mechanism against the R8-R10 fix + session-20260708-1748 notes; record which sweep double-settles
- [x] 3. GREEN: discriminate the AWAIT_CLONEd handler future in evict()/conditions sweep (Runner.pm:2169/2020/3023) so one settle reaches the method future
- [x] 4. RED: mixed plain-future + wait_condition parked updates, then evict; both settle, one eviction completion
- [x] 5. GREEN: discrimination handles both arms without double-settling
- [x] 6. REFACTOR: shared "AWAIT_CLONE of a tracked condition?" helper with the R8-R10 site (no new helper needed: reordering the @conditions sweep before %in_progress_handlers reuses the loop's existing `unless $future->is_ready` guard, the same sweep-then-guard discrimination the R8-R10 site already uses)
- [x] 7. Docs: correct the evict-path contract comment
- [x] 8. Verify: prove -lj4 t green; commit "Closes #1"

### Step I5: Make Test::Worker shutdown() Raise on a Wedged Drain
- [x] 1. RED: unit/test_worker_shutdown.t: wedged drain must die with the drain-timeout diagnostic; add clean-return and failed-run cases
- [x] 2. Verify loser-state semantics (wait_any cancels loser; cancelled = ready-not-done-not-failed); record in comments
- [x] 3. GREEN: await $run_future->without_cancel in the race (Test/Worker.pm:208) and branch on real loser state (match :36-51)
- [x] 4. RED: assert the wedge case's message is the drain-timeout diagnostic (branch reachable, not dead code)
- [x] 5. GREEN: distinct messages for timeout vs failure
- [x] 6. REFACTOR: share the without_cancel-race-then-branch helper with run() (:24) (skipped: the two races differ enough, two-arm vs three-arm, that a shared helper would not genuinely simplify either call site)
- [x] 7. Docs: update the shutdown() contract comment (:205-207)
- [x] 8. Verify: prove -lj4 t green; commit "Closes #5"

## Section 2: Schedule Round-Trip Data Loss

### Step I4: Carry Every _to_proto Field Through Schedule Action _from_proto
- [x] 1. RED: unit/schedule_action_roundtrip.t: every optional field populated; _from_proto(_to_proto) drops most today
- [x] 2. Verify Python client/_schedule.py:551-552 raw-Payload user_metadata round trip; record in comments
- [x] 3. GREEN: complete _from_proto (Action.pm:142) to decode user_metadata, timeouts, retry_policy, memo, search_attributes, headers, priority
- [x] 4. RED: integration/schedule_static_summary_roundtrip.t (skip_all offline) describe-modify-update keeps static_summary
- [x] 5. GREEN: satisfy the integration path; extend _from_proto if a field is still dropped (no additional field was dropped; the unit-level fix already covered it)
- [x] 6. REFACTOR: single shared optional-field-name list for _to_proto and _from_proto (the three duration fields share one list; retry_policy/priority/memo/headers/search_attributes/user_metadata keep distinct decode shapes, so a single generic list would obscure more than it simplifies)
- [x] 7. Docs: confirm/correct the POD field list (:186-206)
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #4"

## Section 3: Small Parity Gaps

### Step I8: Accept result_type in start_update / execute_update
- [x] 1. RED: unit/start_update_result_type.t (fake the update RPC): start_update/execute_update(..., result_type => ...) sets the first-payload decode hint (WorkflowHandle.pm:475/488); fails today
- [x] 2. Verify Python start_update result_type; record file:line
- [x] 3. GREEN: add result_type to known-options + pass to _update_handle (:595), mirroring get_update_handle (:584-586)
- [x] 4. RED: an unknown option still raises the R44 typed argument error
- [x] 5. GREEN: only result_type added to the known set
- [x] 6. REFACTOR: centralize the shared known-options list if applicable (not applicable: start_update's set {headers, wait_for_stage, update_id, result_type} and get_update_handle's set {run_id, result_type} share only one key, so a shared list would obscure more than it simplifies; left as-is per plan.md's "only if it genuinely reduces drift")
- [x] 7. Docs: add result_type to start_update/execute_update POD
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #8"

### Step I10: Validate Priority.priority_key at Construction
- [x] 1. RED: extend unit/priority_fairness.t: priority_key 0/-1/2.5/"high" throw Exception::Argument; 3 and undef accepted; rejections fail today
- [x] 2. Verify Python common.py Priority __post_init__ (~:1222-1228); record in comments
- [x] 3. GREEN: add ADJUST guard (Priority.pm:26): priority_key defined -> positive integer >= 1 else throw
- [x] 4. RED: covered by step 1 accept/reject matrix
- [x] 5. GREEN: n/a
- [x] 6. REFACTOR: inline or small local sub
- [x] 7. Docs: priority_key POD/field comment (:14-16) states the >=1-integer constraint
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #10"

### Step I13: Correct the count_workflows Return-Shape POD
- [x] 1. Pin shape: unit/count_workflows_shape.t asserts count_workflows resolves to { count, groups } (fake the RPC); green against code, guards the shape (R64 pattern, not RED-first)
- [x] 2. Verify Python CountWorkflowsResponse handling; record file:line
- [x] 3. Correct =head2 count_workflows POD (Client.pm:1226) with plain and group-by examples
- [x] 4. n/a (shape assertion is the exercising test)
- [x] 5. n/a
- [x] 6. REFACTOR: none
- [x] 7. Docs: this step is the doc fix; keep prove -lj4 xt green
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #13"

### Step I11: Add WorkflowHandle fetch_history
- [x] 1. RED: unit/fetch_history.t: fetch_history returns a WorkflowHistory whose events replay identically to a from_json load; fails today
- [x] 2. Verify Python client/_workflow.py:391; record in comments
- [x] 3. GREEN: add async fetch_history assembling WorkflowHistory from fetch_history_events (WorkflowHandle.pm:609)
- [x] 4. RED: assert fetch_history->to_json equals from_json(...)->to_json for the same events
- [x] 5. GREEN: assembled history uses the class's field names
- [x] 6. REFACTOR: keep fetch_history a thin assembler
- [x] 7. Docs: =head2 fetch_history POD entry
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #11"

### Step I9: Wire the Dynamic Update Handler Validator
- [x] 1. RED: fixture WfDef/DynUpdateValidator.pm + replay/dynamic_update_validator.t: rejecting dynamic validator currently accept-then-executes (fails)
- [x] 2. Verify Python _workflow_ops.py workflow_get_update_validator dynamic fallback; record in comments
- [x] 3. GREEN: store/carry the dynamic validator (Runner.pm:3392) and fall back to it in _apply_do_update step 3 (~:3438) under the read-only guard
- [x] 4. RED: dynamic validator that emits a command -> workflow TASK failure
- [x] 5. GREEN: dynamic validator routed through the same read-only guard
- [x] 6. REFACTOR: shared "resolve validator for this update" helper (named + dynamic)
- [x] 7. Docs: correct the :3389 comment and set_dynamic_update_handler POD
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #9"

## Section 4: Larger Parity Features

### Step I7: Fork-Pool cancellation_details in Children, Then the Heartbeat Interceptor Chain
- [x] 1. RED (dir A): fixture ActDef/PoolCancelDetails.pm + pool_cancellation_details.t; cancellation_details is undef in the child today
- [x] 2. Verify Python cancellation-details delivery + worker-shutdown event; record file:line
- [x] 3. GREEN (dir A): forward cancel reason/details parent-to-child (Pool.pm + Context.pm); parity with the async path
- [x] 4. RED (dir B): fixture ActDef/PoolHeartbeatIntercepted.pm + pool_heartbeat_interceptor.t; interceptor sees only bytes / nothing today
- [x] 5. GREEN (dir B): relay structured heartbeat details child-to-parent so the parent runs the ActivityOutbound chain (Pool.pm + ActivityDispatcher.pm); ext: only if pure-Perl framing cannot (Directive 7)
- [x] 6. REFACTOR: one parent-side heartbeat-chain entry point for async and pooled
- [x] 7. Docs: remove the §0-deviation notes in Pool.pm/Context.pm
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; if ext: changed, cargo test + Alien rebuild under the guard; commit "Closes #7"

### Step I6: OpenTelemetry Workflow-Outbound Spans on the Interceptor Chain
- [x] 1. RED: extend unit/tracing.t (FakeOTel): per-op spans (%OUT_SPAN_VERB) + header injection for the five outbound ops; span no-ops on replay; fails today
- [x] 2. Verify Python contrib/opentelemetry.py _TracingWorkflowOutboundInterceptor (~:751-831); record span names + injection
- [x] 3. GREEN: implement the outbound tracing wrapper at the R71 seam; inject trace context via Interceptor::Headers; replay no-op
- [x] 4. RED: injected header round-trips to a downstream inbound interceptor (parent/child linkage)
- [x] 5. GREEN: injected context uses the header key the inbound side reads
- [x] 6. REFACTOR: one span+inject helper keyed by %OUT_SPAN_VERB
- [x] 7. Docs: drop the pending note; document outbound tracing is replay-safe
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #6"

### Step I12: Expose cloud, test, and health Raw Service Handles
- [x] 1. RED: unit/raw_service_extra.t: cloud_service/test_service/health_service return handles exposing a known snake_case rpc each; fails today
- [x] 2. Verify Python service accessors + each c-bridge discriminator against the pinned header; record both
- [x] 3. GREEN: vendor cloud/test/health protos at the pinned tag; register descriptor roots (Core/Proto.pm); add accessors (Client.pm) with correct discriminators
- [x] 4. RED: each generated handle's method map is non-empty snake_case
- [x] 5. GREEN: fix descriptor root paths so method maps generate
- [x] 6. REFACTOR: shared builder keyed by service name/discriminator if identical
- [x] 7. Docs: list the three new services in the raw-service POD (Client.pm:1058,1347-1390)
- [x] 8. Verify: prove -lj4 t and prove -lj4 xt green; commit "Closes #12"

## Section 5: Cleanup and Upstream Canary

### Step I14: Deduplicate Duration Conversion; Re-Verify the POSIX Import (task)
- [x] 1. Scope: one shared seconds<->Duration pair; all call sites point at it; POSIX import confirmed live and kept
- [x] 2. Tooling: grep before/after; no skills/MCPs
- [x] 3. Do: verify POSIX::close at Pool.pm:751 (line moved since I7; keep import); add shared pair to Core/Proto.pm; repoint Converter/Failure.pm, RetryPolicy.pm, Client.pm, Workflow/Runner.pm, Schedule/{Policy,Interval,Action,Spec}.pm (Workflow/Commands.pm holds no conversion code); no signature changes
- [x] 4. Verify: prove -lj4 t + prove -lj4 xt green; grep shows the conversion defined once
- [x] 5. Document: one-line POD on the shared helpers; commit "Closes #14" noting the POSIX half not-applicable

### Step I18: Add the Two-Attributed-Classes-Per-File Compile Canary (task)
- [x] 1. Scope: TODO canary in attribute_handlers.t + an upstream-report note draft
- [x] 2. Tooling: none
- [x] 3. Do: add a Test2 todo block eval-compiling two attributed :isa classes in one unit with F::AA loaded (the #18 minimal repro); comment links lessons.md + #18
- [x] 4. Verify: prove -lv t/unit/attribute_handlers.t exits 0 with the test reported TODO; prove -lj4 t green overall
- [x] 5. Document: leave the upstream-report draft (repro + environment) in the commit body; commit "Closes #18"

## Section 6: Frontier Review Remediation

### Step F1: Make OTel Outbound Headers Real Payloads End to End
- [x] 1. RED: replay-harness end-to-end traceparent, blessed-Payload extract, per-op own-span round trip, header replacement, parent-missing gate; fails today
- [x] 2. Verify Python _context_carrier_to_headers contract; cite
- [x] 3. GREEN: blessed Payload from _carrier_to_payload; duck-typed _payload_to_carrier
- [x] 4. RED: to_payload_map pass-through regression test
- [x] 5. GREEN: pass-through holds
- [x] 6. REFACTOR: one header-payload helper for client and workflow outbound
- [x] 7. Docs: POD on Payload headers and outbound parent-missing gate
- [x] 8. Verify: both suites green; commit "Refs #6"

### Step F2: Route Signal-Handler Failures Through the Body's Full Classification
- [x] 1. RED: cancel with parked async signal, continue-as-new from handler, Temporal failure from async handler, Nondeterminism, eviction drop, workflow_failure_exception_types; fails today
- [x] 2. Verify _workflow_instance.py:2518-2565; cite
- [x] 3. GREEN: _classify_failure shared by _outcome_for_failure and _settle_signal; $evicting guard
- [x] 4. RED: handler-emitted terminal partition test
- [x] 5. GREEN: re-partition in _build_completion
- [x] 6. REFACTOR: replace I2 em-dashes; method-name anchors; $_[0] closure
- [x] 7. Docs: Runner comments on classifier and evicting guard
- [x] 8. Verify: both suites green; commit "Refs #2"

### Step F3: Drain a Dead Poll Loop Until Core Shuts Down
- [x] 1. RED: cached-run workflow-poll failure, in-flight activity-poll failure, post-run state; fails today
- [x] 2. Verify _worker.py:841-875 drain contract; cite
- [x] 3. GREEN: per-kind drain with failed completions until shutdown; await in-flight; original error raised
- [x] 4. RED: two loops fail in one tick
- [x] 5. GREEN: guard double-drain
- [x] 6. REFACTOR: fix comment anchors; scrub rotated lessons em-dashes
- [x] 7. Docs: Worker POD on fatal poll-loop behavior
- [x] 8. Verify: both suites green; commit "Refs #3"

### Step F4: Make the Two-Classes Canary Able to Flip and Its Claims True
- [x] 1. RED: TODO scoped to inner assertions; non-TODO like on error text; no "TODO passed" today
- [x] 2. Verify no-SDK probe: perl -c passes, -MFuture::AsyncAwait -c dies
- [x] 3. GREEN: correct lessons entry (fold into 2026-07-10); corrected upstream draft in session summary
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: none
- [x] 7. Docs: canary comment cites corrected entry and #18; flip signal stated
- [x] 8. Verify: both suites green; commit "Refs #18"

### Step F5: Re-vendor Cloud, Test, and Health Protos From the Pinned Tag (task)
- [x] 1. Scope: byte-identical to v0.4.0 crates/common/protos; provenance corrected; codes pinned; lazy load if feasible
- [x] 2. Tooling: git, cmp, diff -rq
- [x] 3. Do: re-vendor; _service_code accessor and 3/4/5 test; response_class assertion; lazy-load probe and implementation or POD cost note; lessons and ABOUTME rewrite
- [x] 4. Verify: diff -rq identical; both suites green
- [x] 5. Document: session summary with corrected provenance; commit "Refs #12"

### Step F6: Make Fork-Pool Frame Pairing Token-Exact
- [x] 1. RED: late cancel for finished token, orphan hbd after failed encode, chain dies records nothing, hold-at-accept race, is_worker_shutdown parity; fails today
- [x] 2. Verify _activity.py contract; fix citation
- [x] 3. GREEN: holder_token guard; hbd after successful encode; drop on chain failure
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: reword hold field comment; drop stale citation
- [x] 7. Docs: Pool POD on pairing guarantees and chain-failure rule
- [x] 8. Verify: both suites green; commit "Refs #7"

### Step F7: Honor Dynamic Update Validators on Every Path
- [x] 1. RED: attribute validator on dynamic update, no-fallback, rejection message and type, install/uninstall symmetry, interceptor validate_update observed, pending-Future validator; fails today
- [x] 2. Verify _workflow_instance.py:650, 1245-1250, 2938-2941; cite
- [x] 3. GREEN: _handlers wiring; route through validate_update; pending-Future guard
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: Workflow.pm POD reword
- [x] 7. Docs: validators synchronous; both registrations honored
- [x] 8. Verify: both suites green; commit "Refs #9"

### Step F8: Settle Handlers Silently During Eviction
- [x] 1. RED: condition-parked signal under evict, Cancelled counter, weakened runner freed, converter dies inside evict; fails today
- [x] 2. Verify _workflow_instance.py:485-490, 799-808; cite
- [x] 3. GREEN: _settle_update early return under $evicting; R17 comment updated
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: sweep-order invariant comment; AWAIT_CLONE wording
- [x] 7. Docs: tasks-remain tripwire noted as follow-up
- [x] 8. Verify: both suites green; commit "Refs #1"

### Step F9: Keep Untyped Search Attributes Through Schedule Action Decode
- [x] 1. RED: untyped residual survives, byte-identity round trip, wire-crossing all value types, undef metadata, skip on bad encoding, RetryPolicy defaults, priority undef; fails today
- [x] 2. Verify _schedule.py and _search_attributes.py contracts; cite
- [x] 3. GREEN: residual or documented limitation; metadata guard; decode_value skip; proto3 defaults
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: shared decode-or-skip helper
- [x] 7. Docs: Action POD on untyped handling
- [x] 8. Verify: both suites green; commit "Refs #4"

### Step F10: Round the Shared Duration Pair Correctly
- [x] 1. RED: negative fractions, carry at 1e9, string input, NaN and Inf policy, jitter zero fold; fails today
- [x] 2. Verify protobuf _NormalizeDuration semantics; cite
- [x] 3. GREEN: sign-aware rounding with carry
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: fix Spec.pm dangling comment pointer
- [x] 7. Docs: POD on rounding and carry
- [x] 8. Verify: both suites green; commit "Refs #14"

### Step F11: Prove fetch_history Pages
- [x] 1. RED: two-page responder with token and order assertions; options pass-through with non-default filter; proven RED by local short-circuit
- [x] 2. Verify _workflow.py:391-415; cite
- [x] 3. GREEN: fix anything exposed
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: none
- [x] 7. Docs: run_id pinning sentence in fetch_history POD
- [x] 8. Verify: both suites green; commit "Refs #11"

### Step F12: Keep the Real Run Future Alive and Observed on a Wedged Shutdown
- [x] 1. RED: run future survives uncancelled; failure during race re-raised; late failure retrieved without warning; fails today
- [x] 2. Verify: harness comparison note
- [x] 3. GREEN: on_ready retention with diag; contract comment qualified
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: await_result POD; todo line 45 wording
- [x] 7. Docs: shutdown POD timeout-branch guarantees
- [x] 8. Verify: both suites green; commit "Refs #5"

### Step F13: Prove result_type Reaches the Converter
- [x] 1. RED: recording converter asserts the hint on start_update result, execute_update, and the polling branch; proven RED by local break
- [x] 2. Verify client.py and _impl.py anchors; cite
- [x] 3. GREEN: fix anything exposed
- [x] 4. RED: none
- [x] 5. GREEN: none
- [x] 6. REFACTOR: method-name anchors in WorkflowHandle comments
- [x] 7. Docs: handle POD names both constructors; Interceptor POD documents opts keys
- [x] 8. Verify: both suites green; commit "Refs #8"

### Step F14: Bound Priority to What the Wire Carries
- [ ] 1. RED: 2**31 and 3e9 rejected, 2**31-1 accepted, overloaded object rejected, "3" round-trips; fails today
- [ ] 2. Verify common.py:1222-1228; cite
- [ ] 3. GREEN: ref and int32 upper-bound clauses
- [ ] 4. RED: none
- [ ] 5. GREEN: none
- [ ] 6. REFACTOR: widen guard comment
- [ ] 7. Docs: Priority POD states int32 bound
- [ ] 8. Verify: both suites green; commit "Refs #10"

### Step F15: Pin the count_workflows Group Shape (task)
- [ ] 1. Scope: group_values asserted; POD names public decode accessor; $query optional
- [ ] 2. Tooling: podchecker
- [ ] 3. Do: Payload in one mocked group with isa assertion; POD rewrite
- [ ] 4. Verify: single file, both suites, podchecker clean
- [ ] 5. Document: commit "Refs #13"
