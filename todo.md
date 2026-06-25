# Temporalio Perl SDK — TODO

Tracks plan.md step-by-step. `/bpe:execute-plan` checks items off as
RED/GREEN/REFACTOR sub-steps complete. Spec test IDs in parentheses.

## Phase 0 — Foundations

### P0.1 Repository scaffold + SDK distribution skeleton
- [x] P0.1.1 RED: sdk/t/00-load.t (SDK loads, VERSION 0.1.0)
- [x] P0.1.2 GREEN: monorepo dirs, Temporalio::SDK, dist.ini, cpanfile, .gitignore
- [x] P0.1.3 RED: sdk/t/unit/attribute_handlers.t (four §10.1 constraints)
- [x] P0.1.4 GREEN: regression test passes
- [x] P0.1.5 REFACTOR: ABOUTME headers everywhere
- [x] P0.1.6 Verify: prove -lj4 t

### P0.2 Exception base + core subclasses
- [x] P0.2.1 RED: sdk/t/unit/exception.t (message/throw/cause chain/stack_trace)
- [x] P0.2.2 GREEN: Exception.pm + Argument/Runtime/Bridge
- [x] P0.2.3 REFACTOR: cause-chain stringifier
- [x] P0.2.4 Verify

### P0.3 Alien::Temporalio::Core
- [x] P0.3.1 RED: alien-core/t/alien.t (T-alien-1, T-alien-3, T-alien-4)
- [x] P0.3.2 GREEN: alienfile + Alien module + dist.ini
- [x] P0.3.3 REFACTOR: cargo diagnostics per spec §2 failure modes
- [x] P0.3.4 Verify: dzil test with local sdk-rust override

### P0.4 Rust shim crate
- [x] P0.4.1 RED: cargo tests (T-shim-1..4 + user_data pair routing)
- [x] P0.4.2 GREEN: queue/user_data/trampolines/drain + cbindgen header
- [x] P0.4.3 REFACTOR: generic enqueue helper
- [x] P0.4.4 Verify: cargo test && cargo build --release

### P0.5 Alien::Temporalio::PerlBridge
- [x] P0.5.1 RED: alien-perl-bridge/t/alien.t (T-alien-pb-1..3)
- [x] P0.5.2 GREEN: alienfile + Alien module + dist.ini
- [x] P0.5.3 Verify: dzil test

### P0.6 Temporalio::Core::FFI
- [x] P0.6.1 RED: sdk/t/unit/core_ffi.t (T-ffi-1..3)
- [x] P0.6.2 GREEN: FFI.pm, opaque/record types, Phase-0 attach set
- [x] P0.6.3 REFACTOR: table-driven attach
- [x] P0.6.4 Verify

### P0.7 Temporalio::Core::ByteArray
- [x] P0.7.1 RED: sdk/t/unit/byte_array.t (T-ba-1..4 + dead-runtime warn)
- [x] P0.7.2 GREEN: ByteArray.pm
- [x] P0.7.3 Verify

### P0.8 Telemetry config classes
- [x] P0.8.1 RED: sdk/t/unit/runtime_config.t (T-rt-4, T-rt-6, validation)
- [x] P0.8.2 GREEN: TelemetryConfig/LoggingConfig/LoggingFilter/OTel/Prometheus
- [x] P0.8.3 GREEN: to_ffi builders
- [x] P0.8.4 Verify

### P0.9 Temporalio::Runtime
- [x] P0.9.1 RED: sdk/t/unit/runtime.t (T-rt-1, T-rt-2, T-rt-3, T-rt-5 + idempotent shutdown)
- [x] P0.9.2 GREEN: Runtime.pm (runtime_new, queue, fd, shutdown sequence)
- [x] P0.9.3 REFACTOR: fd creation into Core::Callback stub
- [x] P0.9.4 Verify

### P0.10 Risk spike 3 — WorkerOptions marshalling
- [x] P0.10.1 RED: shim debug_worker_options echo + cargo test
- [x] P0.10.2 GREEN: regen header, rebuild Alien
- [x] P0.10.3 RED: sdk/t/unit/worker_options_marshal.t (full struct echo match)
- [x] P0.10.4 GREEN: FFI/WorkerOptions.pm records (or pack() fallback, documented)
- [x] P0.10.5 Update spec §11: spike 3 CLOSED with mechanism
- [x] P0.10.6 Verify: cargo test + prove

### P0.11 Vendor protos + Temporalio::Core::Proto
- [x] P0.11.1 Vendor full api_upstream + local trees via xt/author/vendor-protos.pl
- [x] P0.11.2 RED: sdk/t/unit/proto.t (T-proto-1..5)
- [x] P0.11.3 GREEN: Core/Proto.pm (Parser + Generator + resolve)
- [x] P0.11.4 REFACTOR: measure load time; lazy-build only if >2s
- [x] P0.11.5 Verify — **Phase 0 acceptance green**

## Phase 1 — Client smoke

### P1.1 Temporalio::Cancellation
- [x] P1.1.1 RED: sdk/t/unit/cancellation.t (T-can-1..3)
- [x] P1.1.2 GREEN: Cancellation.pm + FFI attaches
- [x] P1.1.3 Verify

### P1.2 Core::Callback issue_async + drain
- [x] P1.2.1 RED: sdk/t/unit/callback.t (T-cb-1..4 + shutdown sentinel)
- [x] P1.2.2 GREEN: Callback.pm full implementation
- [x] P1.2.3 REFACTOR: per-kind dispatch table
- [x] P1.2.4 Verify

### P1.3 Ephemeral dev server
- [x] P1.3.1 RED: sdk/t/integration/dev_server.t (start/shutdown/two ports)
- [x] P1.3.2 GREEN: FFI attaches + Test/DevServer.pm
- [x] P1.3.3 Verify

### P1.4 Payload converters
- [x] P1.4.1 RED: sdk/t/unit/converter_payload.t (T-pay-1..5 + binary forms)
- [x] P1.4.2 GREEN: Payload base/composite + five subclasses + Payload record
- [x] P1.4.3 Verify

### P1.5 Full exceptions + Failure converter
- [x] P1.5.1 RED: exception.t extension (T-exc-1, T-exc-4, table-driven §6.2)
- [x] P1.5.2 GREEN: all §6.2 subclasses
- [x] P1.5.3 RED: sdk/t/unit/converter_failure.t (T-fail-1..4 + §5.3 table)
- [x] P1.5.4 GREEN: Converter/Failure.pm
- [x] P1.5.5 Verify

### P1.6 PayloadCodec + Converter::Data
- [x] P1.6.1 RED: sdk/t/unit/converter_data.t (T-conv-1..4)
- [x] P1.6.2 GREEN: PayloadCodec.pm + Data.pm + TestCodec.pm
- [x] P1.6.3 Verify

### P1.7 Client connect + configs + update_api_key
- [x] P1.7.1 RED: sdk/t/unit/client_config.t (PEM detection, defaults, identity)
- [x] P1.7.2 GREEN: TlsConfig/RetryConfig/KeepAliveConfig
- [x] P1.7.3 RED: sdk/t/integration/client_connect.t (T-cli-connect-1..4)
- [x] P1.7.4 GREEN: Client->connect + Connection.pm + FFI attaches
- [x] P1.7.5 Verify

### P1.8 client_rpc_call + error mapping
- [x] P1.8.1 RED: sdk/t/unit/rpc_mapping.t (§7.5 table-driven)
- [x] P1.8.2 GREEN: rpc branch in Callback.pm
- [x] P1.8.3 RED: sdk/t/integration/client_rpc.t (DescribeNamespace, NotFound, retry flag)
- [x] P1.8.4 GREEN: _rpc_call helper + FFI attach
- [x] P1.8.5 Verify

### P1.9 Common types
- [x] P1.9.1 RED: sdk/t/unit/common_types.t (RetryPolicy proto, SA typed keys, untyped → Argument)
- [x] P1.9.2 GREEN: RetryPolicy/Priority/SearchAttributeKey/TypedSearchAttributes
- [x] P1.9.3 Verify

### P1.10 start_workflow + WorkflowHandle
- [x] P1.10.1 RED: sdk/t/unit/start_workflow_request.t (kwargs→proto, policies, T-cli-start-3/4)
- [x] P1.10.2 GREEN: start_workflow/get_workflow_handle/signal_with_start + handle fields
- [x] P1.10.3 RED: sdk/t/integration/start_workflow.t (T-cli-start-1/2)
- [x] P1.10.4 GREEN: wire until green
- [x] P1.10.5 Verify

### P1.11 result + describe/cancel/terminate + list/count
- [x] P1.11.1 RED: sdk/t/unit/workflow_handle_result.t (§7.6 terminal-event table)
- [x] P1.11.2 GREEN: handle methods + list/count iterators
- [x] P1.11.3 RED: integration (T-cli-result-3, terminate-1, describe-1, cancel-1, list-1)
- [x] P1.11.4 GREEN: wire until green
- [x] P1.11.5 Verify — **Phase 1 acceptance green** (reference-worker cases → P3.9)

## Phase 2 — Worker + activities

### P2.1 Activity definitions + registry
- [x] P2.1.1 RED: sdk/t/unit/activity_definition.t (T-act-1..4, T-wkr-2)
- [x] P2.1.2 GREEN: Activity.pm/Definition/Attributes/FunctionDefinition + registry
- [x] P2.1.3 Verify

### P2.2 Worker construction + validate
- [x] P2.2.1 RED: sdk/t/unit/worker_new.t (T-wkr-1, kwargs→options echo)
- [x] P2.2.2 RED: sdk/t/integration/worker_new.t (validate, clean shutdown, T-wkr-5)
- [x] P2.2.3 GREEN: Worker.pm construction/validate/shutdown + FFI attaches
- [x] P2.2.4 Verify

### P2.3 Activity::Context + heartbeat
- [x] P2.3.1 RED: sdk/t/unit/activity_context.t (context scoping, heartbeat proto, T-act-7 unit)
- [x] P2.3.2 GREEN: Context.pm + heartbeat FFI attach
- [x] P2.3.3 Verify

### P2.4 Activity poll loop (async)
- [x] P2.4.1 RED: sdk/t/unit/activity_dispatch.t (T-act-5/8/9, cancel variant, codec, token map)
- [x] P2.4.2 GREEN: ActivityDispatcher.pm + PollLoop.pm activity loop + FFI attaches
- [x] P2.4.3 GREEN: Worker->run wiring + shutdown (T-wkr-4)
- [x] P2.4.4 REFACTOR: shared completion builder
- [x] P2.4.5 Verify

### P2.5 Sync activity fork pool
- [x] P2.5.1 RED: sdk/t/unit/activity_pool.t (T-act-6, T-act-10, heartbeat relay, coop cancel)
- [x] P2.5.2 GREEN: Pool.pm + dispatcher routing
- [x] P2.5.3 REFACTOR: cross-fork invocation struct
- [x] P2.5.4 Verify — **Phase 2 acceptance green (unit level)**

## Phase 3 — Workflows

### P3.1 Workflow::Definition + attributes
- [x] P3.1.1 RED: sdk/t/unit/workflow_definition.t (:Run/:Signal/:Query/:Update/:Init, duplicates)
- [x] P3.1.2 GREEN: Workflow.pm/Definition/Attributes + registry
- [x] P3.1.3 Verify

### P3.2 Workflow::Future
- [x] P3.2.1 RED: sdk/t/unit/workflow_future.t (manual resolve, on_cancel order)
- [x] P3.2.2 GREEN: Workflow/Future.pm
- [x] P3.2.3 Verify

### P3.3 Runner core + replay harness
- [x] P3.3.1 RED: sdk/t/replay/runner_basics.t (trivial complete, now/time, NoRunner, seed T-wf-10)
- [x] P3.3.2 GREEN: Runner.pm skeleton + Commands.pm + Test/WorkflowReplay.pm
- [x] P3.3.3 REFACTOR: pump loop per §10.3
- [x] P3.3.4 Verify

### P3.4 execute_activity + ResolveActivity
- [x] P3.4.1 RED: sdk/t/replay/activities.t (T-wf-1/2/7, seq allocation)
- [x] P3.4.2 GREEN: execute_activity/start_activity + job handling
- [x] P3.4.3 Verify

### P3.5 Timers
- [x] P3.5.1 RED: sdk/t/replay/timers.t (T-wf-6, sleep alias, CancelTimer)
- [x] P3.5.2 GREEN: start_timer/sleep + FireTimer
- [x] P3.5.3 Verify

### P3.6 Workflow poll loop + cache + eviction
- [x] P3.6.1 RED: sdk/t/unit/workflow_poll_loop.t (routing, T-wf-14, eviction-last, codec, shutdown)
- [x] P3.6.2 GREEN: WorkflowDispatcher.pm + workflow loop + RemoveFromCache teardown
- [x] P3.6.3 GREEN: Worker->run runs both loops
- [x] P3.6.4 Verify

### P3.7 Completion outcomes
- [x] P3.7.1 RED: sdk/t/replay/completion_outcomes.t (T-wf-12, T-wf-15a/b/c, T-wf-8, T-wf-13)
- [x] P3.7.2 GREEN: outcome decision table + continue_as_new + CancelWorkflow
- [x] P3.7.3 Verify

### P3.8 Determinism primitives
- [x] P3.8.1 RED: sdk/t/replay/determinism.t (UpdateRandomSeed, T-wf-9 logger, NotifyHasPatch)
- [x] P3.8.2 GREEN: random/logger/patch handlers
- [x] P3.8.3 Verify

### P3.9 End-to-end + hello-world
- [x] P3.9.1 RED: sdk/t/integration/end_to_end.t (greeting, timer, activity failure)
- [x] P3.9.2 GREEN: integration fixes only
- [x] P3.9.3 examples/hello-world/
- [x] P3.9.4 REFACTOR: promote reusable test glue
- [x] P3.9.5 Verify — **Phase 3 acceptance green**

## Phase 4 — Signals & queries

### P4.1 Signals in the runner
- [x] P4.1.1 RED: sdk/t/replay/signals.t (T-wf-3, queueing, async handler tracking)
- [x] P4.1.2 GREEN: SignalWorkflow + pending_signals + handler tracking
- [x] P4.1.3 Verify

### P4.2 Queries
- [x] P4.2.1 RED: sdk/t/replay/queries.t (T-wf-4, dying handler, queries-last)
- [x] P4.2.2 GREEN: QueryWorkflow + RespondToQuery
- [x] P4.2.3 Verify

### P4.3 wait_condition
- [x] P4.3.1 RED: sdk/t/replay/wait_condition.t (T-wf-5, timeout, re-check per pump)
- [x] P4.3.2 GREEN: wait_condition
- [x] P4.3.3 Verify

### P4.4 Client signal/query end-to-end
- [x] P4.4.1 RED: sdk/t/integration/signals_queries.t (T-cli-signal-1, T-cli-query-1/2)
- [x] P4.4.2 GREEN: integration fixes only
- [x] P4.4.3 examples/greet-with-signal/
- [x] P4.4.4 Verify — **Phase 4 acceptance green**

## Phase 5 — Hardening

### P5.1 Cancellation end-to-end
- [x] P5.1.1 RED: sdk/t/integration/cancellation.t (cancel chain, abandon type)
- [x] P5.1.2 GREEN: propagation fixes
- [x] P5.1.3 Verify

### P5.2 RPC special-case audit
- [x] P5.2.1 RED: sdk/t/integration/error_paths.t (T-cli-result-2/4/5)
- [x] P5.2.2 GREEN: mapping fixes
- [x] P5.2.3 Verify

### P5.3 POD + author tests + README
- [x] P5.3.1 RED: xt/pod-coverage.t + xt/pod-syntax.t
- [x] P5.3.2 GREEN: hand-written POD everywhere
- [x] P5.3.3 README.md (root + sdk/)
- [x] P5.3.4 Verify: prove -lj4 xt t

### P5.4 CI matrix
- [x] P5.4.1 .github/workflows/ci.yml per spec §14
- [x] P5.4.2 Verify: green on feature branch

### P5.5 v0.1.0 release prep
- [x] P5.5.1 RED: version-agreement test
- [x] P5.5.2 GREEN: set versions across dists
- [x] P5.5.3 Update spec §11 + plan Current Status
- [x] P5.5.4 Verify: full sweep green

# Part II — v0.2 feature parity

## Phase 6 — Workflow feature parity

### P6.1 Child workflows (spec §18)
- [x] P6.1.1 RED: sdk/t/replay/child_workflows.t (T-child-1..12) + WfDef fixtures
- [x] P6.1.2 GREEN: execute/start_child_workflow + ChildWorkflowHandle + Commands builders + Runner resolve/seq/cancel-propagation
- [x] P6.1.3 RED: sdk/t/integration/child_workflows.t (T-child-13)
- [x] P6.1.4 GREEN: wire until green vs dev server
- [x] P6.1.5 REFACTOR: share two-future resolve with activity path if duplicated
- [x] P6.1.6 Verify: prove -lj4 t

### P6.2 Workflow updates (spec §19)
- [x] P6.2.1 RED: sdk/t/replay/updates.t (T-upd-1..11) + WfDef fixtures
- [x] P6.2.2 GREEN: do_update dispatch + validator guard + tracked handler + UpdateResponse builder + buffer-then-drain; relax the v0.1 hard completion-gate to warn-and-complete + expose all_handlers_finished (M1) + update the affected v0.1 signal test
- [x] P6.2.3 RED: sdk/t/integration/updates.t (T-cli-update-1..7)
- [x] P6.2.4 GREEN: WorkflowHandle->execute_update/start_update + WorkflowUpdateHandle + Exception::WorkflowUpdateFailed
- [x] P6.2.5 Verify: prove -lj4 t

### P6.3 External workflow handles (spec §20)
- [x] P6.3.1 RED: sdk/t/replay/external_workflow.t (T-ext-1..9) + WfDef fixtures
- [x] P6.3.2 GREEN: get_external_workflow_handle + ExternalWorkflowHandle + Commands builders + Runner two-counter resolve + namespace injection
- [x] P6.3.3 RED: sdk/t/integration/external_workflow.t (T-ext-10)
- [x] P6.3.4 GREEN: wire until green
- [x] P6.3.5 Verify: prove -lj4 t — **Phase 6 acceptance: workflow parity green**

## Phase 7 — Activity feature parity

### P7.1 Local activities (spec §21)
- [x] P7.1.1 RED: sdk/t/replay/local_activities.t (T-local-1..15) + WfDef fixtures
- [x] P7.1.2 GREEN: execute/start_local_activity + ScheduleLocalActivity/RequestCancelLocalActivity + backoff→timer loop (runner-owned)
- [x] P7.1.3 REFACTOR: share resolve/cancel paths with regular activities
- [x] P7.1.4 Verify: prove -lj4 t

### P7.2 Async activity completion (spec §22)
- [x] P7.2.1 RED: sdk/t/unit/async_activity.t + sdk/t/integration/async_activity.t (T-asyncact-1..9)
- [x] P7.2.2 GREEN: Client->async_activity_handle + AsyncActivityHandle + CompleteAsync/AsyncActivityCancelled exceptions + complete_async + WillCompleteAsync reporting
- [x] P7.2.3 Verify: prove -lj4 t

### P7.3 Eager start (spec §23)
- [x] P7.3.1 RED: sdk/t/unit/eager.t + sdk/t/integration/eager.t (T-eager-1..6)
- [x] P7.3.2 GREEN: WorkflowHandle->eagerly_started; Worker disable_eager_activity_execution + no_remote_activities; thread eager flag through schedule_activity
- [x] P7.3.3 Verify: prove -lj4 t

### P7.4 In-workflow upsert search-attributes & memo (spec §24)
- [x] P7.4.1 RED: sdk/t/replay/upsert.t (T-upsert-1..9) + WfDef fixtures
- [x] P7.4.2 GREEN: upsert_search_attributes/upsert_memo + Commands builders + Runner conversion/info-view + SearchAttributeKey value_set/value_unset
- [x] P7.4.3 Verify: prove -lj4 t — **Phase 7 acceptance: activity parity green**

## Phase 8 — Scheduling

### P8.1 Schedule data classes + Client methods (spec §25)
- [x] P8.1.1 RED: sdk/t/unit/schedule_types.t + schedule_request.t (proto remaps, default ranges, invariants, T-sched-unit)
- [x] P8.1.2 GREEN: Schedule.pm + Schedule/* data classes + Client create/get/list_schedules + ScheduleListIterator + Exception/ScheduleAlreadyRunning
- [x] P8.1.3 Verify: prove -lj4 t/unit

### P8.2 ScheduleHandle ops + integration (spec §25)
- [x] P8.2.1 RED: sdk/t/unit/schedule_handle.t + sdk/t/integration/schedule.t (T-sched-1..7)
- [x] P8.2.2 GREEN: Client/ScheduleHandle.pm (describe/delete/backfill/trigger/pause/unpause/update)
- [x] P8.2.3 Verify: prove -lj4 t — **Phase 8 acceptance: schedules green**

## Phase 9 — Nexus

### P9.1 Nexus caller side (spec §26)
- [x] P9.1.1 RED: sdk/t/replay/nexus.t (T-nexus-1..9) + WfDef fixtures
- [x] P9.1.2 GREEN: create_nexus_client + NexusClient + NexusOperationHandle + Commands builders + Runner two-stage resolve/seq/cancel + cancellation-type map
- [x] P9.1.3 Verify: prove -lj4 t

### P9.2 Nexus handler side (spec §26)
- [x] P9.2.1 RED: sdk/t/unit/nexus_definition.t + sdk/t/integration/nexus.t (T-nexus-10..14)
- [x] P9.2.2 GREEN: Nexus/{Definition,OperationContext,OperationResult,WorkflowHandle} + Worker/NexusDispatcher + NexusRegistry + Worker nexus_services + gRPC→Nexus error table
- [x] P9.2.3 Verify: prove -lj4 t — **Phase 9 acceptance: Nexus green**

## Phase 10 — Runtime, observability & worker hardening

### P10.0 Integration-test shutdown hardening
- [x] P10.0.1 RED: sdk/t/unit/worker_shutdown_tolerance.t — _shutdown_error_is_tolerable classifies transport-teardown bridge failures (ConnectionReset/BrokenPipe/connection closed/transport error) as tolerable, all else not
- [x] P10.0.2 GREEN: Worker.pm _finalize_and_free swallows tolerable shutdown-time transport errors (still frees worker, returns clean) + rethrows real errors; Test::Worker::shutdown retrieves run-future outcome so a failed future is never abandoned; audit all 16 t/integration/*.t ordered teardown (already consistent)
- [x] P10.0.3 Verify: full prove -lj4 t 5x consecutive all exit 0; signals_queries.t 10x standalone all exit 0; forced concurrent contention triggers transport WARN yet every run exits 0
- [x] P10.0.4 Complete the fix (prior dispatch was incomplete, real flake was contention-amplified `Cannot finalize, expected 1 reference, got N` finalize Arc-refcount race re-raised by Test::Worker::shutdown, killing the test before done_testing): RED extends worker_shutdown_tolerance.t for the finalize-race; GREEN adds the `Cannot finalize, expected N reference` pattern to the tolerance classifier and hardens Test::DevServer->shutdown to swallow the same teardown-shaped transport errors; remove the contention amplification via sdk/.proverc `--rules=seq=t/integration/*.t`/`--rules=par=**` so integration files run sequentially (one dev server at a time) while unit/replay stay parallel — command stays `prove -lj4 t`. Verify: full prove -lj4 t 6x consecutive all exit 0 (429 tests each)

### P10.1 Interceptor framework (spec §27)
- [x] P10.1.1 RED: sdk/t/unit/interceptors.t + replay fixtures (T-icpt-1..10)
- [x] P10.1.2 GREEN: Client + Worker interceptor base classes + Input classes + chain build/install + interceptors => [] args
- [x] P10.1.3 Verify: prove -lj4 t

### P10.2 OpenTelemetry tracing interceptor (spec §27.4)
- [x] P10.2.1 RED: sdk/t/unit/tracing.t (T-trace-1..9, skip_all without OTel)
- [x] P10.2.2 GREEN: Contrib/OpenTelemetry/TracingInterceptor + durable_scheduler_disabled Runner primitive + W3C fallback
- [x] P10.2.3 Verify: prove -lj4 t

### P10.3 core→Perl log forwarding (spec §28.1)
- [x] P10.3.1 RED: cargo test (kind-7 deep-copy, shutdown free) + sdk/t/unit/log_forwarding.t (T-logfwd-1..7)
- [x] P10.3.2 GREEN: LogForwardingConfig + LoggingConfig forward_to + shim 7th trampoline/kind-7/free/Drop + Callback drain builder + global registry
- [x] P10.3.3 Verify: cargo test && prove -lj4 t

### P10.4 Custom metric meters (spec §28.2)
- [ ] P10.4.1 RED: cargo test (8-thread aggregate) + sdk/t/unit/metric_meter.t + sdk/t/integration/metrics.t (T-meter-1..10)
- [ ] P10.4.2 GREEN: Runtime/MetricMeter + TelemetryConfig custom_meter to_ffi + shim 8-callback set (aggregate record_*, marshal create/free)
- [ ] P10.4.3 Verify: cargo test && prove -lj4 t

### P10.5 Worker versioning (spec §29.1)
- [ ] P10.5.1 RED: sdk/t/unit/worker_versioning.t + sdk/t/integration/deployment_versioning.t (T-wkrver-1..9; 6-9 = override/ramp/legacy, gated/skip)
- [ ] P10.5.2 GREEN: DeploymentOptions/DeploymentVersion + Worker kwargs + WorkerOptions versioning packers + :VersioningBehavior attribute + MD5-%INC build_id
- [ ] P10.5.3 Verify: prove -lj4 t

### P10.6 Slot suppliers / worker tuner (spec §29.2)
- [ ] P10.6.1 RED: sdk/t/unit/tuner.t + cargo test + integration (T-tuner-1..7)
- [ ] P10.6.2 GREEN: Tuner + SlotSupplier/{FixedSize,ResourceBased,Custom} + context classes + WorkerOptions packers + shim custom-supplier callbacks
- [ ] P10.6.3 Verify: cargo test && prove -lj4 t

### P10.7 Autoscaling pollers (spec §29.3)
- [ ] P10.7.1 RED: sdk/t/unit/poller_behavior.t + integration smoke (T-poller-1..5)
- [ ] P10.7.2 GREEN: PollerBehavior/{SimpleMaximum,Autoscaling} + Worker *_poller_behavior kwargs + override resolution + WorkerOptions packer
- [ ] P10.7.3 Verify: prove -lj4 t

### P10.8 Determinism enforcement (spec §29.4)
- [ ] P10.8.1 RED: sdk/t/unit/determinism_guard.t + WfDef fixtures (T-det-1..7)
- [ ] P10.8.2 GREEN: Workflow/Unsafe + Workflow/DeterminismGuard (CORE::GLOBAL:: overrides gated on context + dynamically-scoped suppression) + worker disable kwarg
- [ ] P10.8.3 Verify: prove -lj4 t — **Phase 10 worker-hardening green**

### P10.9 Client extras — reset + http_proxy (spec §30)
- [ ] P10.9.1 RED: sdk/t/unit/reset.t + http_proxy.t + integration (T-reset-1..5, T-proxy-1..5)
- [ ] P10.9.2 GREEN: WorkflowHandle->reset + Client->reset_workflow; HttpConnectProxyConfig + ClientHttpConnectProxyOptions FFI record + wire Client.pm:589
- [ ] P10.9.3 Verify: prove -lj4 t

### P10.10 Client environment configuration (spec §31)
- [ ] P10.10.1 RED: sdk/t/unit/envconfig.t (options-struct build, FFI-JSON parse, fail→Argument, to_connect_config; T-envcfg-1..9) + integration (T-envcfg-int-1)
- [ ] P10.10.2 GREEN: Temporalio/EnvConfig + EnvConfig/{ClientConfigTLS,ClientConfigProfile,ClientConfig} via the env-config FFI (load/_profile_load, parse JSON) — NOT a pure-Perl port; + pin check for the two symbols
- [ ] P10.10.3 Verify: prove -lj4 t — **v0.2 SDK feature contracts complete**
