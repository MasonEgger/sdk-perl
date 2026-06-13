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
- [ ] P3.2.1 RED: sdk/t/unit/workflow_future.t (manual resolve, on_cancel order)
- [ ] P3.2.2 GREEN: Workflow/Future.pm
- [ ] P3.2.3 Verify

### P3.3 Runner core + replay harness
- [ ] P3.3.1 RED: sdk/t/replay/runner_basics.t (trivial complete, now/time, NoRunner, seed T-wf-10)
- [ ] P3.3.2 GREEN: Runner.pm skeleton + Commands.pm + Test/WorkflowReplay.pm
- [ ] P3.3.3 REFACTOR: pump loop per §10.3
- [ ] P3.3.4 Verify

### P3.4 execute_activity + ResolveActivity
- [ ] P3.4.1 RED: sdk/t/replay/activities.t (T-wf-1/2/7, seq allocation)
- [ ] P3.4.2 GREEN: execute_activity/start_activity + job handling
- [ ] P3.4.3 Verify

### P3.5 Timers
- [ ] P3.5.1 RED: sdk/t/replay/timers.t (T-wf-6, sleep alias, CancelTimer)
- [ ] P3.5.2 GREEN: start_timer/sleep + FireTimer
- [ ] P3.5.3 Verify

### P3.6 Workflow poll loop + cache + eviction
- [ ] P3.6.1 RED: sdk/t/unit/workflow_poll_loop.t (routing, T-wf-14, eviction-last, codec, shutdown)
- [ ] P3.6.2 GREEN: WorkflowDispatcher.pm + workflow loop + RemoveFromCache teardown
- [ ] P3.6.3 GREEN: Worker->run runs both loops
- [ ] P3.6.4 Verify

### P3.7 Completion outcomes
- [ ] P3.7.1 RED: sdk/t/replay/completion_outcomes.t (T-wf-12, T-wf-15a/b/c, T-wf-8, T-wf-13)
- [ ] P3.7.2 GREEN: outcome decision table + continue_as_new + CancelWorkflow
- [ ] P3.7.3 Verify

### P3.8 Determinism primitives
- [ ] P3.8.1 RED: sdk/t/replay/determinism.t (UpdateRandomSeed, T-wf-9 logger, NotifyHasPatch)
- [ ] P3.8.2 GREEN: random/logger/patch handlers
- [ ] P3.8.3 Verify

### P3.9 End-to-end + hello-world
- [ ] P3.9.1 RED: sdk/t/integration/end_to_end.t (greeting, timer, activity failure)
- [ ] P3.9.2 GREEN: integration fixes only
- [ ] P3.9.3 examples/hello-world/
- [ ] P3.9.4 REFACTOR: promote reusable test glue
- [ ] P3.9.5 Verify — **Phase 3 acceptance green**

## Phase 4 — Signals & queries

### P4.1 Signals in the runner
- [ ] P4.1.1 RED: sdk/t/replay/signals.t (T-wf-3, queueing, async handler tracking)
- [ ] P4.1.2 GREEN: SignalWorkflow + pending_signals + handler tracking
- [ ] P4.1.3 Verify

### P4.2 Queries
- [ ] P4.2.1 RED: sdk/t/replay/queries.t (T-wf-4, dying handler, queries-last)
- [ ] P4.2.2 GREEN: QueryWorkflow + RespondToQuery
- [ ] P4.2.3 Verify

### P4.3 wait_condition
- [ ] P4.3.1 RED: sdk/t/replay/wait_condition.t (T-wf-5, timeout, re-check per pump)
- [ ] P4.3.2 GREEN: wait_condition
- [ ] P4.3.3 Verify

### P4.4 Client signal/query end-to-end
- [ ] P4.4.1 RED: sdk/t/integration/signals_queries.t (T-cli-signal-1, T-cli-query-1/2)
- [ ] P4.4.2 GREEN: integration fixes only
- [ ] P4.4.3 examples/greet-with-signal/
- [ ] P4.4.4 Verify — **Phase 4 acceptance green**

## Phase 5 — Hardening

### P5.1 Cancellation end-to-end
- [ ] P5.1.1 RED: sdk/t/integration/cancellation.t (cancel chain, abandon type)
- [ ] P5.1.2 GREEN: propagation fixes
- [ ] P5.1.3 Verify

### P5.2 RPC special-case audit
- [ ] P5.2.1 RED: sdk/t/integration/error_paths.t (T-cli-result-2/4/5)
- [ ] P5.2.2 GREEN: mapping fixes
- [ ] P5.2.3 Verify

### P5.3 POD + author tests + README
- [ ] P5.3.1 RED: xt/pod-coverage.t + xt/pod-syntax.t
- [ ] P5.3.2 GREEN: hand-written POD everywhere
- [ ] P5.3.3 README.md (root + sdk/)
- [ ] P5.3.4 Verify: prove -lj4 xt t

### P5.4 CI matrix
- [ ] P5.4.1 .github/workflows/ci.yml per spec §14
- [ ] P5.4.2 Verify: green on feature branch

### P5.5 v0.1.0 release prep
- [ ] P5.5.1 RED: version-agreement test
- [ ] P5.5.2 GREEN: set versions across dists
- [ ] P5.5.3 Update spec §11 + plan Current Status
- [ ] P5.5.4 Verify: full sweep green
