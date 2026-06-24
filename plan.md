# Temporalio Perl SDK — TDD Implementation Plan

Derived from `spec.md` (revised 2026-06-09). The spec is the behavioral
contract; every step below cites the spec section(s) it implements. When a
prompt and the spec disagree, the spec wins. (The old `PLAN.md` architecture
draft has been removed; spec.md is the sole contract.)

## Current Status

- **v0.1.0 COMPLETE (P0.1–P5.5, 2026-06-13).** Every step in this plan is
  implemented and `todo.md` has zero unchecked items. All five phase gates
  (spec §11) are accepted: distributions scaffolded and building, the FFI +
  callback bridge live, client/worker/workflow/signals-queries end-to-end
  against the ephemeral dev server, the full exception hierarchy and
  cancellation round-tripping, POD coverage enforced in `xt/`, a runnable
  `examples/hello-world/`, the GitHub Actions CI matrix (spec §14), and a
  consistent `0.1.0` dist version across all three distributions plus the
  Rust shim crate (guarded by `sdk/t/unit/version.t`).
  `Alien::Temporalio::Core->version` reports the pinned upstream sdk-core
  release (`0.4.0`), tracked independently of the Perl dist version. Tagging
  and release to `main` are performed manually by the maintainer.
- **v0.2 (feature parity) IN PROGRESS. Phase 6 (workflow parity) COMPLETE
  (P6.1–P6.3).** P6.1 child workflows and P6.2 workflow updates landed
  earlier; P6.3 external workflow handles (spec §20) is now done:
  `Temporalio::Workflow::get_external_workflow_handle` (synchronous,
  non-command constructor; NoRunner outside a body) returns a new
  `Temporalio::Workflow::ExternalWorkflowHandle` whose `signal`/`cancel`
  emit `SignalExternalWorkflowExecution` /
  `RequestCancelExternalWorkflowExecution` on the `workflow_execution`
  oneof arm (NamespacedWorkflowExecution{namespace, workflow_id, run_id})
  through the COMMAND stream, resolved on the matching Resolve* job. The
  Runner now owns TWO independent seq spaces (external-signal, shared with
  child-targeted signals; external-cancel) and injects the namespace from
  `Temporalio::Workflow::info` (threaded worker → WorkflowDispatcher →
  Runner from `$client->namespace`; the replay harness takes a `namespace`
  param). New Commands builders:
  `request_cancel_external_workflow_execution`, `cancel_signal_workflow`
  (an in-flight signal cancel emits CancelSignalWorkflow{seq} without
  pre-emptively raising; a cancel has no counter-cancel). Resolve failures
  go through `failure_converter->from_failure` verbatim (a not-found is an
  Exception::Application — no bespoke exception). T-ext-1..9
  (`sdk/t/replay/external_workflow.t`) + T-ext-10
  (`sdk/t/integration/external_workflow.t`, live against the dev server).
  **Phase 6 acceptance (workflow parity) green.** Phases 7–10 (activity
  parity, scheduling, Nexus, runtime/worker hardening) are scoped in spec
  §11 and authored into spec.md before their steps are added here.
- The historical phase-by-phase detail below is retained as the build record.

- **Phase 0: COMPLETE (P0.1–P0.11, 2026-06-12).** Acceptance per spec §11
  is green: distributions scaffolded, shim + Aliens build, FFI attaches,
  Runtime lifecycle works, protos vendored and loaded
  (`Temporalio::Core::Proto`, T-proto-1..5; eager load measured at ~1.7s,
  under the 2s lazy-build threshold).
- Dependency `Protobuf` (protobuf-perl) is complete and verified against
  the full Temporal proto graph (`proto3-perl/verification-2026-06-09.md`).
- Risk spikes: #1 proto loading CLOSED; #2 attributes CLOSED; #3
  WorkerOptions marshalling CLOSED (hand-packed `pack()` buffer verified
  via the shim's debug_worker_options echo — spec §11, step P0.10).
- **Phase 1 in progress.** P1.1 `Temporalio::Cancellation` complete
  (T-can-1..3; the three cancellation_token FFI functions were already in
  the Phase-0 attach set). P1.2 `Core::Callback` complete (T-cb-1..4 +
  shutdown sentinel; per-kind dispatch table; runtime fd watcher now runs
  the real drain loop). P1.3 `Temporalio::Test::DevServer` complete
  (start/target/shutdown over the callback bridge; DevServerOptions +
  TestServerOptions records gcc-probe-verified; integration test runs the
  real `temporal` CLI via existing_path and skip_alls when no CLI is
  found — no download is ever attempted in tests). P1.4 payload
  converters complete (T-pay-1..5 + binary forms; the five spec
  encodings in spec order; `Temporalio::Payload` is a transparent
  subclass of the generated `temporal.api.common.v1.Payload` class;
  `Core::Proto` now exposes `schema()`/`json()` for the proto3 JSON
  form). P1.5 complete: every spec §6.2 exception subclass exists (one
  file per class; spec naming `WorkflowNotFound` et al. wins over the
  plan's `NotFound::Workflow` shorthand) and
  `Temporalio::Converter::Failure` round-trips the §5.3 info-type table
  with cause chains (enum fields cross as lowercased Temporal-spec
  strings; unknown info warns once and degrades to Application). P1.6
  complete: `Temporalio::Converter::PayloadCodec` (async abstract base)
  and `Temporalio::Converter::Data` facade (codecs encode in list order,
  decode in reverse; failure payload traversal mirrors sdk-python's
  `_apply_to_failure_payloads`; codec/converter errors surface as
  DataConverter); `Failure->default` added per spec §5.1. CAUTION: with
  Future::AsyncAwait loaded, only ONE `class X :isa(Y)` parses per file
  on perl 5.38.2 — keep one :isa class per file (the test codecs are
  split into sdk/t/lib/TestCodec/*.pm for this reason). P1.7 complete:
  `Temporalio::Client->connect` (async, T-cli-connect-1..4 live against
  the dev server) + `Client::Connection` (ptr owner, update_api_key,
  close/free) + Tls/Retry/KeepAlive configs (MUST-match defaults verified
  against sdk-python service.py and sdk-ruby connection.rb; NOTE the
  local sdk-rust checkout's `RetryOptions::default` drifted to multiplier
  1.7 upstream — spec §7.2 and both reference SDKs say 1.5, spec wins);
  ConnectionOptions/ClientTlsOptions/ClientRetryOptions/
  ClientKeepAliveOptions records + client_connect/client_free/
  client_update_api_key attaches in Core::FFI (metadata is a
  ByteArrayRefArray — entry COUNT, not byte length; built via the new
  `keep_byte_array_ref_array`). P1.8 complete: the §7.5 MUST-match
  mapping lives in `Temporalio::Core::Callback::rpc_error_for` (status
  names verified against sdk-python service.py RPCStatusCode; the
  ALREADY_EXISTS→WorkflowAlreadyStarted unpack verified against
  sdk-python client/_impl.py and sdk-ruby implementation.rb);
  `Client->_rpc_call` (async, retry=1 default, response class derived
  from the request class) over the RpcCallOptions record (gcc offsetof
  probe: sizeof 96) + client_rpc_call attach; google/rpc/status.proto
  newly vendored (sdk-rust's standalone google/ root — vendor-protos.pl
  updated) and parsed as an explicit proto root alongside
  errordetails/v1/message.proto (both reachable only via Any). P1.9
  complete: `Temporalio::Common::{RetryPolicy,Priority,SearchAttributeKey,
  TypedSearchAttributes}` — RetryPolicy/Priority `to_proto` (seconds →
  google.protobuf.Duration, defaults MUST-match sdk-python common.py:
  initial 1s/backoff 2.0/max_interval None/attempts 0), the typed-SA
  system (IndexedValueType numbers TEXT 1…KEYWORD_LIST 7, PascalCase
  metadata.type, json/plain payload encoding verified against sdk-python
  converter/_search_attributes.py), and the spec §7.4 untyped-input guard
  (bare hashref / non-SearchAttributeKey pair → Exception::Argument; no
  type guessing). TypedSearchAttributes->new is positional (\@pairs) via a
  glob wrapper over the feature-class constructor. P1.10 complete:
  `Client->start_workflow`/`signal_with_start_workflow`/`execute_workflow`
  (async) build the Start/SignalWithStart-WorkflowExecutionRequest from the
  spec §7.4 kwargs (id_reuse/id_conflict policy strings → proto enum numbers,
  MUST-match temporal.api.enums.v1.WorkflowId{Reuse,Conflict}Policy
  introspected from the vendored proto: reuse unspecified 0/allow_duplicate 1/
  allow_duplicate_failed_only 2/reject_duplicate 3/terminate_if_running 4;
  conflict unspecified 0/fail 1/use_existing 2/terminate_existing 3 — cross-
  checked against sdk-python common.py + _impl.py `_populate_start_workflow_
  execution_request`), funnel through `_rpc_call` (ALREADY_EXISTS special-
  cased to WorkflowAlreadyStarted), and return a `Client::WorkflowHandle`
  (fields-only in v0.1; result/describe/cancel/terminate land in P1.11).
  `get_workflow_handle` builds a handle with no RPC. NOTE: the generated
  proto accessors are READ-ONLY, so every field (incl. signal_name/
  signal_input) must arrive via `new(\%fields)` — setters silently no-op.
  NOTE: a bare Perl string arg/memo/header value encodes binary/plain (the
  P1.4 composite puts BinaryPlain before Json and a string IS a byte buffer);
  this differs from sdk-python's json/plain for str, by design — the wire
  payload is the SDK's own converter output. T-cli-start-1..4 green
  (start_workflow_request.t unit + start_workflow.t integration, run live
  against the dev server). P1.11 complete: `Client::WorkflowHandle` gained
  the behavioural methods — `result` long-polls GetWorkflowExecutionHistory
  with the CLOSE_EVENT filter (history_event_filter_type 2, introspected) and
  maps the §7.6 terminal event (MUST-match, verified against sdk-python
  client/_workflow.py result lines 186-316: Completed→decoded payload;
  Failed→WorkflowFailure wrapping data_converter->from_failure; TimedOut→
  WorkflowFailure cause Timeout; Canceled→cause Cancelled; Terminated→cause
  Terminated w/ reason; ContinuedAsNew→follow new_execution_run_id when
  follow_runs else WorkflowContinuedAsNew) — plus describe/cancel/terminate/
  signal/query/fetch_history_events (request shapes from sdk-python _impl.py
  cancel/describe/terminate/signal/query 344-534, threading
  first_execution_run_id). New async page iterators:
  `Client::_HistoryEventIterator` (GetWorkflowExecutionHistory by
  next_page_token) backs result + fetch_history_events;
  `Client::_WorkflowExecutionIterator` backs `Client->list_workflows`
  (ListWorkflowExecutions paging); `Client->count_workflows` returns
  { count, groups }. NOTE: Terminated carries `reason` only (no `details`
  field) — do NOT pass details to its constructor. NOTE: `_new_uuid`'s
  Data::UUID probe moved to a load-time `my $HAVE_DATA_UUID` with `local $@`
  — a lazy `state` probe whose `require` fails inside an async frame
  (cancel/signal) gets the failure re-raised by Future::AsyncAwait. Unit
  (workflow_handle_result.t, mocked _rpc_call over Future->done/fail) +
  integration (T-cli-result-3/terminate-1/describe-1/cancel-1/list-1, run
  live, no worker — terminate/timeout drive the terminal event server-side,
  cancel verified via a cancel-requested history event). **Phase 1
  acceptance green** except the reference-worker cases (T-cli-result-1/2/4/5,
  signal/query against a running worker) handled in P3.9. (Phases 2–5 then
  completed through P5.5 — see the v0.1.0 COMPLETE summary at the top.)

Progress tracking lives in `todo.md`. Update both as steps complete.

---

## Phase 0 — Foundations (no Temporal server)

### Step P0.1: Repository scaffold + SDK distribution skeleton

**NOTE**: Monorepo layout per spec §1. Preserve `sdk/t/spike/` as-is.

```text
1. RED: Write load tests first:
   - Create sdk/t/00-load.t (Test2::V1 preamble per spec §12.1):
     - Test that Temporalio::SDK loads and $Temporalio::SDK::VERSION is '0.1.0'
2. GREEN: Write MINIMAL code to make tests pass:
   - Create directories: alien-core/, alien-perl-bridge/, sdk/lib, sdk/t,
     sdk/xt, sdk/examples, sdk/share/proto/, ext/temporalio-perl-bridge/
   - Create sdk/lib/Temporalio/SDK.pm (ABOUTME header; version only)
   - Create sdk/dist.ini using [@Starter::Git] per spec §1/§16.6
   - Create sdk/cpanfile listing runtime deps from spec (FFI::Platypus,
     Future::AsyncAwait, IO::Async, Syntax::Keyword::Dynamically, Protobuf
     from git, Test2::V1 etc. — see spec §16)
   - Add .gitignore entries: commit-msg.md, sdk/t/tmp/, target/, .build/
3. RED: Add regression test for the attribute-handler spike:
   - Create sdk/t/unit/attribute_handlers.t porting sdk/t/spike/ proofs to
     Test2::V1 (the four constraints from spec §10.1 — guard against Perl
     version regressions)
4. GREEN: No new code expected — the test exercises core Perl behavior the
   SDK depends on; fix the test, not the language
5. REFACTOR: Ensure every new .pm starts with the two-line ABOUTME comment
6. Verify: cd sdk && prove -lj4 t
```

### Step P0.2: Exception base class + core subclasses

**NOTE**: Spec §6.1, §16.1. Needed before Runtime (P0.9) — its error paths
raise these. Full hierarchy lands in P1.5; only base + 3 subclasses here.

```text
1. RED: Write exception tests first:
   - Create sdk/t/unit/exception.t:
     - Test Temporalio::Exception->new(message => 'x')->message eq 'x' (T-exc-1 shape)
     - Test ->throw(%fields) dies with a catchable object (T-exc-2)
     - Test stringification of a 3-deep cause chain: "foo: caused by: bar:
       caused by: baz" (T-exc-3)
     - Test cause must be an exception object — ADJUST validation raises
       Temporalio::Exception::Argument on a plain scalar
     - Test stack_trace is populated via Devel::StackTrace
2. GREEN: Write MINIMAL code to make tests pass:
   - Create sdk/lib/Temporalio/Exception.pm (feature 'class', overloaded "",
     fields message/stack_trace/cause per spec §6.1)
   - Create sdk/lib/Temporalio/Exception/Argument.pm, Runtime.pm, Bridge.pm
3. REFACTOR: Extract the cause-chain stringifier into one method
4. Verify: cd sdk && prove -lj4 t/unit/exception.t && prove -lj4 t
```

### Step P0.3: Alien::Temporalio::Core (local-path build)

**NOTE**: Spec §2. Network-fetch path is specified but CI/dev use the
`ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH` override. Tests must
`skip_all` unless that env var and `cargo` are available.

```text
1. RED: Write Alien behavior tests first:
   - Create alien-core/t/alien.t:
     - Test that with the override env set, dynamic_libs returns an existing,
       DynaLoader-loadable file (T-alien-1)
     - Test that with the override set to a nonexistent path, build dies with
       "path does not exist" before invoking cargo (T-alien-3)
     - Test ->version returns the pinned tag string (T-alien-4)
2. GREEN: Write MINIMAL code to make tests pass:
   - Create alien-core/alienfile: probe always "share"; if override env set,
     skip download and cargo-build the pointed-at tree
     (`cargo build --release -p temporalio-sdk-core-c-bridge`); else
     Download+Digest+Extract per spec §2; install cdylib + header to share dir
   - Create alien-core/lib/Alien/Temporalio/Core.pm (dynamic_libs,
     include_dir, version)
   - Create alien-core/dist.ini ([@Starter::Git])
3. REFACTOR: Factor the cargo invocation + diagnostics (cargo missing →
   rustup URL; build failure → verbatim output) per spec §2 failure modes
4. Verify: ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH=<sdk-rust checkout>
   cpanm --look/dzil test in alien-core/ — T-alien-1/3/4 pass
```

### Step P0.4: Rust shim crate `temporalio-perl-bridge`

**NOTE**: Spec §3 — queue, user_data pairs, six trampolines, drain,
eventfd/pipe signal. Rust-side TDD with `cargo test`.

```text
1. RED: Write Rust tests first:
   - Create ext/temporalio-perl-bridge/src/lib.rs test module:
     - Test 1000 entries pushed from 8 threads drain completely, no
       duplicates (T-shim-1)
     - Test signal write happens per push; EAGAIN is not retried (T-shim-2)
     - Test queue_free leaves no entries (T-shim-3)
     - Test pipe-fd fallback semantics match eventfd (T-shim-4)
     - Test user_data pair: temporalio_perl_bridge_user_data_new(q, 42)
       routes an entry with callback_id 42 to queue q and the pair is freed
       (no double-free under miri/asan if available)
2. GREEN: Write MINIMAL code to make tests pass:
   - Create ext/temporalio-perl-bridge/Cargo.toml (deps: crossbeam-queue,
     libc; build-dep cbindgen; links against sdk-core-c-bridge types via the
     header — declare the TemporalCore* structs as opaque/borrowed per spec §3)
   - Implement queue_new/queue_free/user_data_new/queue_drain + the six
     trampolines + six *_callback_ptr accessors exactly as spec §3 C ABI
   - Create ext/temporalio-perl-bridge/cbindgen.toml; generate
     include/temporalio-perl-bridge.h in build.rs
3. REFACTOR: One generic enqueue helper; trampolines stay ~5 lines each
4. Verify: cd ext/temporalio-perl-bridge && cargo test && cargo build --release
```

### Step P0.5: Alien::Temporalio::PerlBridge

**NOTE**: Spec §2.1 — builds the in-tree shim; depends on Alien core for the
upstream header.

```text
1. RED: Write Alien behavior tests first:
   - Create alien-perl-bridge/t/alien.t:
     - Test build succeeds and dynamic_libs returns a loadable .so (T-alien-pb-1)
     - Test include_dir contains temporalio-perl-bridge.h (T-alien-pb-3)
     - Test missing Alien::Temporalio::Core produces the install-instructions
       diagnostic (T-alien-pb-2; simulate by masking the module via @INC hook)
2. GREEN: Write MINIMAL code to make tests pass:
   - Create alien-perl-bridge/alienfile (source = in-tree ext/ dir; cargo
     build --release; copy .so + generated header to share dir)
   - Create alien-perl-bridge/lib/Alien/Temporalio/PerlBridge.pm + dist.ini
3. Verify: dzil test in alien-perl-bridge/ with both Aliens installed
```

### Step P0.6: Temporalio::Core::FFI

**NOTE**: Spec §4.1. Loads both cdylibs, attaches the Phase-0 function set.
Record-by-value returns (`TemporalCoreRuntimeOrFail`) are a known Platypus
risk — if record return fails, fall back to a thin out-param wrapper added
to the shim (document which path was taken).

```text
1. RED: Write FFI load tests first:
   - Create sdk/t/unit/core_ffi.t:
     - Test `use Temporalio::Core::FFI` succeeds and the expected wrapper
       subs exist in the symbol table (T-ffi-1): runtime_new, runtime_free,
       byte_array_free, cancellation_token_new/cancel/free, queue_new,
       queue_free, queue_drain, user_data_new, the six *_callback_ptr
     - Test runtime_new/runtime_free round-trip with default options (T-ffi-2)
     - Test load failure diagnostic includes the attempted path (T-ffi-3;
       point Platypus at a bogus lib path in a subprocess)
2. GREEN: Write MINIMAL code to make tests pass:
   - Create sdk/lib/Temporalio/Core/FFI.pm: one FFI::Platypus (api => 2)
     loading Alien::Temporalio::Core->dynamic_libs +
     Alien::Temporalio::PerlBridge->dynamic_libs
   - Declare opaque types and the records needed so far
     (TemporalCoreByteArrayRef, TemporalCoreRuntimeOptions,
     TemporalCoreTelemetryOptions, TemporalCoreLoggingOptions) per spec §4.1
   - Attach only the Phase-0 set listed in the RED test; die loudly on
     attach failure (version-skew detection per spec §4.1)
3. REFACTOR: Table-driven attach list (name, args, ret) — one loop
4. Verify: cd sdk && prove -lj4 t/unit/core_ffi.t && prove -lj4 t
```

### Step P0.7: Temporalio::Core::ByteArray

**NOTE**: Spec §4.3. Needs a real runtime ptr for the free path.

```text
1. RED: Write ByteArray tests first:
   - Create sdk/t/unit/byte_array.t:
     - Test wrap + ->bytes returns known contents (T-ba-1; craft a
       TemporalCoreByteArray record in Perl with disable_free=1 over a
       Perl-owned buffer)
     - Test ->bytes after ->free raises Runtime "ByteArray freed" (T-ba-2)
     - Test DESTROY invokes free exactly once (T-ba-3; count via a mock of
       the FFI free sub)
     - Test repeated ->free is idempotent (T-ba-4)
     - Test dead runtime weakref → warn + skip free (spec §4.3 failure mode)
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Core/ByteArray.pm per spec §4.3 (weak runtime
     ref, lazy bytes cache via FFI::Platypus::Buffer)
3. Verify: cd sdk && prove -lj4 t/unit/byte_array.t
```

### Step P0.8: Telemetry config classes (pure Perl)

**NOTE**: Spec §4.2 config classes. No MetricBuffer, no LogForwarding
(removed/deferred). Pure validation — no FFI in tests.

```text
1. RED: Write config tests first:
   - Create sdk/t/unit/runtime_config.t:
     - Test TelemetryConfig with both OTel and Prometheus raises Argument (T-rt-4)
     - Test LoggingFilter(core_level => 'INFO', other_level => 'WARN')
       produces the exact filter string other SDKs produce (T-rt-6)
     - Test OpenTelemetryConfig/PrometheusConfig field validation (bad
       temporality string, bad protocol → Argument)
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Runtime/TelemetryConfig.pm, LoggingConfig.pm,
     LoggingFilter.pm, OpenTelemetryConfig.pm, PrometheusConfig.pm
3. GREEN: Add a to_ffi method on each producing the matching FFI record(s)
   (unit-assert field values, not layout — layout is P0.10's job)
4. Verify: cd sdk && prove -lj4 t/unit/runtime_config.t
```

### Step P0.9: Temporalio::Runtime

**NOTE**: Spec §4.2 behavior. Eventfd via Linux::FD::Event on Linux, pipe
fallback elsewhere; fd choice hidden behind Temporalio::Core::Callback's
handle (stub the watcher here; full drain loop is P1.2).

```text
1. RED: Write runtime lifecycle tests first:
   - Create sdk/t/unit/runtime.t:
     - Test ->new with defaults succeeds; queue allocated; fd open (T-rt-1)
     - Test ->default returns the same instance repeatedly (T-rt-2)
     - Test set_default errors by default on second call; replaces with
       error_if_already_set => 0 (T-rt-3)
     - Test after ->shutdown, operations raise "Runtime is shut down" (T-rt-5)
     - Test ->shutdown is idempotent and DESTROY warns if relied upon
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Runtime.pm per spec §4.2: build
     TemporalCoreRuntimeOptions via P0.8 configs, call runtime_new, check
     RuntimeOrFail.fail, allocate shim queue + wakeup fd, register read end
     with IO::Async::Loop, shutdown sequence steps 1-6
3. REFACTOR: Extract fd creation (eventfd vs pipe) into
   sdk/lib/Temporalio/Core/Callback.pm as a constructor-only stub
4. Verify: cd sdk && prove -lj4 t/unit/runtime.t && prove -lj4 t
```

### Step P0.10: Risk spike 3 — WorkerOptions marshalling

**NOTE**: Spec §11 Phase 0 spike 3, §8.1 mapping. Proves Platypus can build
the by-value tagged-union tree. Adds a debug echo function to the shim so
no server/connection is needed: the shim parses the struct it receives and
returns a printable summary ByteArray.

```text
1. RED: Write Rust-side echo tests first:
   - In ext/temporalio-perl-bridge: add
     temporalio_perl_bridge_debug_worker_options(const TemporalCoreWorkerOptions*)
     returning a newline-delimited "field=value" summary (namespace,
     task_queue, versioning tag+build_id, all four tuner slot-supplier tags
     and fixed sizes, poller behaviors, ratios, shutdown period)
   - cargo test: construct a WorkerOptions in Rust, assert the summary
2. GREEN: regenerate the cbindgen header; rebuild via the Alien
3. RED: Write Perl marshalling tests:
   - Create sdk/t/unit/worker_options_marshal.t:
     - Build the full struct in Perl (versioning None{build_id='b1'}, four
       FixedSize suppliers 100/100/100/100, simple_maximum=5 pollers,
       nonsticky_to_sticky_poll_ratio=0.2, empty plugins/storage_drivers)
       per spec §8.1 mapping
     - Call the echo fn; assert every echoed field matches what Perl set
4. GREEN: Implement record classes in
   sdk/lib/Temporalio/Core/FFI/WorkerOptions.pm (and nested union/record
   helpers). If FFI::Platypus::Record cannot express the unions, hand-pack
   with pack() per the pinned header layout and document it in the module's
   ABOUTME block — this is the spec-sanctioned fallback
5. Update spec §11: mark risk spike 3 CLOSED with the chosen mechanism
6. Verify: cargo test in ext/ AND cd sdk && prove -lj4 t/unit/worker_options_marshal.t
```

### Step P0.11: Vendor protos + Temporalio::Core::Proto

**NOTE**: Spec §4.6. Vendor the COMPLETE api_upstream + local trees from the
pinned sdk-rust tag. Requires the Protobuf dist installed from git.

```text
1. Vendor the protos:
   - Create xt/author/vendor-protos.pl that copies
     <sdk-rust>/crates/protos/protos/api_upstream/** and
     <sdk-rust>/crates/protos/protos/local/** into sdk/share/proto/
     (path from ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH); run it; commit output
2. RED: Write proto loading tests first:
   - Create sdk/t/unit/proto.t:
     - Test Temporalio::Core::Proto->load succeeds and is idempotent (T-proto-1)
     - Test WorkflowActivation round-trip: new({...}) → encode → decode →
       structurally equal (T-proto-2)
     - Test StartWorkflowExecutionRequest round-trip — deepest import chain
       (T-proto-3)
     - Test Failure proto with a 3-deep cause chain round-trips (T-proto-4)
     - Test resolve('temporal.api.failure.v1.Failure') eq
       'Temporalio::Proto::Api::Failure::V1::Failure' (T-proto-5)
3. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Core/Proto.pm per spec §4.6: one
     Protobuf::Parser over share/proto, parse_with_imports on the root
     files, Protobuf::Class::Generator->build per message with the
     mechanical package mapping, resolve() over the registry
4. REFACTOR: Cache schemas; lazy-build only namespaces the SDK touches if
   full generation is slow (>2s) — measure first, don't guess
5. Verify: cd sdk && prove -lj4 t/unit/proto.t && prove -lj4 t
   Phase 0 acceptance (spec §11) is now fully green.
```

---

## Phase 1 — Client smoke

### Step P1.1: Temporalio::Cancellation

**NOTE**: Spec §4.4. Small, synchronous, no callbacks.

```text
1. RED: Write token tests first:
   - Create sdk/t/unit/cancellation.t:
     - Test new token: is_cancelled false, ->cancelled Future pending (T-can-1)
     - Test ->cancel: is_cancelled true; pending Future resolves; later
       ->cancelled returns already-resolved (T-can-2)
     - Test repeated ->cancel is idempotent (T-can-3)
2. GREEN: Create sdk/lib/Temporalio/Cancellation.pm per spec §4.4; attach
   the three cancellation_token FFI functions in Core::FFI if missing
3. Verify: cd sdk && prove -lj4 t/unit/cancellation.t
```

### Step P1.2: Temporalio::Core::Callback — issue_async + drain loop

**NOTE**: Spec §4.5. The heart of async dispatch. Tests simulate completions
by invoking trampoline pointers directly via FFI with Perl-crafted
ByteArrays (disable_free=1) — no server needed.

```text
1. RED: Write callback bridge tests first:
   - Create sdk/t/unit/callback.t:
     - Test issue_async returns a pending Future; invoking the worker_poll
       trampoline (via its *_callback_ptr through FFI) with a crafted
       success ByteArray then running the loop resolves it with the bytes
       (T-cb-1)
     - Test 1000 concurrent issue_async calls all resolve (T-cb-2)
     - Test a stale callback_id is warned + dropped, not fatal (T-cb-3)
     - Test drain honors cap=256 per call and loops until empty (T-cb-4)
     - Test null/null worker_poll completion resolves the Future with undef
       (shutdown sentinel, spec §4.5)
2. GREEN: Write MINIMAL code:
   - Implement sdk/lib/Temporalio/Core/Callback.pm fully per spec §4.5:
     monotonic ids, pending hash on the runtime, user_data_new pairing,
     drain loop wired to the runtime's fd watcher, per-kind result
     construction, byte-array freeing after consumption
3. REFACTOR: Per-kind result builders as a dispatch table keyed on entry.kind
4. Verify: cd sdk && prove -lj4 t/unit/callback.t && prove -lj4 t
```

### Step P1.3: Ephemeral dev server + Temporalio::Test::DevServer

**NOTE**: Spec §12.2. First true integration surface. Tests that need it must
skip cleanly when the binary can't download (offline CI).

```text
1. RED: Write dev-server tests first:
   - Create sdk/t/integration/dev_server.t:
     - Test DevServer->start returns an object with a host:port target
     - Test ->shutdown is idempotent
     - Test two servers in one process get distinct ports
2. GREEN: Write MINIMAL code:
   - Attach temporal_core_ephemeral_server_start_dev_server / _shutdown +
     TemporalCoreDevServerOptions/TestServerOptions records in Core::FFI
   - Create sdk/lib/Temporalio/Test/DevServer.pm per spec §12.2 (callback
     bridge for start/shutdown; Net::EmptyPort for the port; stderr to
     t/tmp/dev-server.<pid>.log)
3. Verify: cd sdk && prove -lj4 t/integration/dev_server.t
```

### Step P1.4: Payload converters

**NOTE**: Spec §5.2. All five encodings; proto classes exist from P0.11.

```text
1. RED: Write payload converter tests first:
   - Create sdk/t/unit/converter_payload.t:
     - Test undef → binary/null → undef (T-pay-1)
     - Test { a => 1 } → json/plain (canonical JSON::PP) → { a => 1 } (T-pay-2)
     - Test a generated Temporalio::Proto::* message → json/protobuf with
       messageType metadata → structurally same (T-pay-3)
     - Test BinaryProto-hinted message → binary/protobuf round-trip
     - Test raw-bytes value → binary/plain round-trip
     - Test unhandled blessed object → Exception::DataConverter naming the
       class (T-pay-4)
     - Test custom subclass registered first wins (T-pay-5)
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Converter/Payload.pm (abstract + composite,
     spec order: BinaryNull, BinaryPlain, JsonProtobuf, BinaryProtobuf, Json)
   - Create the five subclasses under sdk/lib/Temporalio/Converter/Payload/
   - Create sdk/lib/Temporalio/Payload.pm (payload record: metadata+data)
     and Temporalio::Payload::RawBytes / ::BinaryProto hint wrappers
3. Verify: cd sdk && prove -lj4 t/unit/converter_payload.t
```

### Step P1.5: Full exception hierarchy + Failure converter

**NOTE**: Spec §6.2, §5.3. Everything start_workflow/activities/workflows
will throw. Mapping table in §5.3 is MUST-match.

```text
1. RED: Write hierarchy tests first:
   - Extend sdk/t/unit/exception.t:
     - Test Application(type,non_retryable,details) accessors (T-exc-1)
     - Test RpcTimeout isa RpcError (T-exc-4)
     - Test every class in spec §6.2 exists with its listed fields
       (table-driven), including QueryRejected, WorkflowContinuedAsNew,
       Workflow::NoRunner, NotFound::{Workflow,Activity,Namespace}
2. GREEN: Create one file per subclass under sdk/lib/Temporalio/Exception/
   per spec §6.2
3. RED: Write failure converter tests:
   - Create sdk/t/unit/converter_failure.t:
     - Test Application round-trip incl. type/non_retryable/details (T-fail-1)
     - Test 3-deep cause chain Application→Activity→Application (T-fail-2)
     - Test unknown failure_info → generic Application, warns once (T-fail-3)
     - Test plain string die → Application with type
       'Temporalio::Exception::Plain' (T-fail-4)
     - Test every row of the spec §5.3 info-type table dispatches to the
       right class (table-driven)
4. GREEN: Create sdk/lib/Temporalio/Converter/Failure.pm per spec §5.3
5. Verify: cd sdk && prove -lj4 t/unit/exception.t t/unit/converter_failure.t
```

### Step P1.6: PayloadCodec base + Converter::Data facade

**NOTE**: Spec §5.4, §5.1. Codec order is spec-mandated: encode in order,
decode in reverse.

```text
1. RED: Write data-converter tests first:
   - Create sdk/t/unit/converter_data.t:
     - Test no-codec JSON round-trip of a hashref (T-conv-1)
     - Test single XOR test-codec encode→decode round-trip (T-conv-2)
     - Test codecs A,B: encode A-then-B, decode B-then-A — order recorded by
       mock codecs (T-conv-3)
     - Test to_failure/from_failure pass embedded payloads through the codec
       chain (T-conv-4)
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Converter/PayloadCodec.pm (async encode/decode
     contract per spec §5.4)
   - Create sdk/lib/Temporalio/Converter/Data.pm per spec §5.1
   - Create sdk/t/lib/TestCodec.pm (XOR + call-order recorder used above)
3. Verify: cd sdk && prove -lj4 t/unit/converter_data.t && prove -lj4 t
```

### Step P1.7: Client connect + TLS/Retry/KeepAlive configs + update_api_key

**NOTE**: Spec §7.1–§7.3. ConnectionOptions is pointer-rich but union-free —
easier than P0.10. PEM path-vs-content detection per spec §7.2.

```text
1. RED: Write config unit tests first:
   - Create sdk/t/unit/client_config.t:
     - Test TlsConfig detects PEM content (leading -----BEGIN) vs readable
       path vs garbage → Argument (T-cli-connect-3 precondition)
     - Test RetryConfig defaults equal sdk-core defaults exactly (spec §7.2
       table); KeepAliveConfig defaults interval=30/timeout=15
     - Test identity default is "<pid>@<hostname>"
2. GREEN: Create sdk/lib/Temporalio/Client/TlsConfig.pm, RetryConfig.pm,
   KeepAliveConfig.pm with to_ffi record builders
3. RED: Write connect integration tests:
   - Create sdk/t/integration/client_connect.t (DevServer-backed):
     - Test connect succeeds; client has expected namespace + identity
       (T-cli-connect-1)
     - Test TLS against the non-TLS dev server raises RpcError with an
       informative message (T-cli-connect-2)
     - Test bad PEM raises Argument before any RPC (T-cli-connect-3)
     - Test update_api_key('B') reaches the FFI call (spy) (T-cli-connect-4)
4. GREEN: Write MINIMAL code:
   - Attach client_connect/client_free/client_update_api_key +
     TemporalCoreConnectionOptions records in Core::FFI
   - Create sdk/lib/Temporalio/Client.pm with ->connect per spec §7.3 and
     sdk/lib/Temporalio/Client/Connection.pm holding the connection ptr
5. Verify: cd sdk && prove -lj4 t/unit/client_config.t t/integration/client_connect.t
```

### Step P1.8: client_rpc_call + RPC error → exception mapping

**NOTE**: Spec §7.5 table is MUST-match. Every later client method funnels
through this one helper.

```text
1. RED: Write mapping unit tests first:
   - Create sdk/t/unit/rpc_mapping.t:
     - Table-driven: every row of spec §7.5 (status code → class), including
       the special cases (5→NotFound::*, 6→WorkflowAlreadyStarted on
       start_workflow, 9→QueryRejected on query) and the catch-all RpcError
       with status_name populated
2. GREEN: Implement the mapping in the rpc branch of
   sdk/lib/Temporalio/Core/Callback.pm (decode failure_details as
   google.rpc.Status when present)
3. RED: Write rpc integration tests:
   - Create sdk/t/integration/client_rpc.t (DevServer-backed):
     - Test a raw _rpc_call('DescribeNamespace', $req) round-trips proto
       request/response
     - Test DescribeNamespace on a nonexistent namespace raises
       NotFound::Namespace
     - Test retry flag is set on high-level calls (spy on RpcCallOptions)
4. GREEN: Write MINIMAL code:
   - Attach client_rpc_call + TemporalCoreRpcCallOptions in Core::FFI
   - Add Client->_rpc_call($rpc_name, $request_msg, %opts) — encodes via
     proto classes, awaits callback, decodes typed response, applies mapping
5. Verify: cd sdk && prove -lj4 t/unit/rpc_mapping.t t/integration/client_rpc.t
```

### Step P1.9: Common types — RetryPolicy, Priority, TypedSearchAttributes

**NOTE**: Spec §7.4 (search attribute encoding block is MUST-match).

```text
1. RED: Write common-type tests first:
   - Create sdk/t/unit/common_types.t:
     - Test RetryPolicy fields map to the temporal.api.common.v1.RetryPolicy
       proto correctly (durations → Duration messages)
     - Test SearchAttributeKey->keyword/int/double/bool/datetime/text/
       keyword_list produce payloads with the right metadata.type
     - Test TypedSearchAttributes encodes a pair list into the
       SearchAttributes proto map
     - Test a bare untyped hashref passed as search_attributes raises
       Argument (spec §7.4 — no type guessing)
2. GREEN: Create sdk/lib/Temporalio/Common/RetryPolicy.pm, Priority.pm,
   SearchAttributeKey.pm, TypedSearchAttributes.pm
3. Verify: cd sdk && prove -lj4 t/unit/common_types.t
```

### Step P1.10: start_workflow + WorkflowHandle (construction only)

**NOTE**: Spec §7.4. Handle's result() is P1.11. Validation of policy
strings happens before any RPC.

```text
1. RED: Write request-building unit tests first:
   - Create sdk/t/unit/start_workflow_request.t:
     - Test all kwargs from spec §7.4 land in the right
       StartWorkflowExecutionRequest fields (args via data converter,
       id_reuse/id_conflict enums, retry_policy, memo, search_attributes,
       headers, start_delay → Duration)
     - Test each id_reuse_policy string maps to the right enum value
       (T-cli-start-3, at proto level)
     - Test invalid id_reuse_policy raises Argument pre-RPC (T-cli-start-4)
2. GREEN: Implement Client->start_workflow / ->get_workflow_handle /
   ->signal_with_start_workflow per spec §7.4 + a minimal
   sdk/lib/Temporalio/Client/WorkflowHandle.pm (fields only)
3. RED: Write integration tests:
   - Create sdk/t/integration/start_workflow.t (DevServer-backed):
     - Test start returns handle with workflow_id + run_id (T-cli-start-1)
     - Test reject_duplicate twice → WorkflowAlreadyStarted (T-cli-start-2)
4. GREEN: Wire and fix until green
5. Verify: cd sdk && prove -lj4 t/unit/start_workflow_request.t t/integration/start_workflow.t
```

### Step P1.11: WorkflowHandle->result + describe/cancel/terminate + list/count

**NOTE**: Spec §7.4, §7.6. result() long-polls GetWorkflowExecutionHistory
with CLOSE_EVENT filter; terminal-event mapping is MUST-match. No worker
exists yet — integration uses timeout/terminate paths only.

```text
1. RED: Write result-mapping unit tests first:
   - Create sdk/t/unit/workflow_handle_result.t:
     - Table-driven over crafted history responses: Completed → decoded
       value; Failed → WorkflowFailure with cause chain; TimedOut →
       cause Timeout; Canceled → cause Cancelled; Terminated → cause
       Terminated; ContinuedAsNew follows when follow_runs else raises
       WorkflowContinuedAsNew (spec §7.6 list) — inject responses via a
       mocked _rpc_call
2. GREEN: Implement WorkflowHandle->result/describe/cancel/terminate/
   signal/query/fetch_history_events and Client->list_workflows (async
   iterator) / ->count_workflows per spec §7.4/§7.6
3. RED: Write integration tests (DevServer-backed):
   - Extend sdk/t/integration/start_workflow.t:
     - Test run_timeout=1 workflow with no worker → result raises
       WorkflowFailure(cause Timeout) (T-cli-result-3)
     - Test terminate then result → cause Terminated, reason preserved
       (T-cli-terminate-1)
     - Test describe shows populated workflow_execution_info (T-cli-describe-1)
     - Test cancel → describe shows cancel requested (T-cli-cancel-1)
     - Test list_workflows iterates 3 started workflows (T-cli-list-1)
4. GREEN: Wire and fix until green
5. Verify: cd sdk && prove -lj4 t — Phase 1 acceptance (spec §11) green
   except reference-worker scenarios (T-cli-result-1/5), which are covered
   end-to-end in Phase 3.
```

---

## Phase 2 — Worker + activities

### Step P2.1: Activity definitions + registry

**NOTE**: Spec §9.1–§9.2, §8.5. Attribute constraints from §10.1 apply
identically (verified by spike).

```text
1. RED: Write registration tests first:
   - Create sdk/t/unit/activity_definition.t:
     - Test a class with `async method run :Defn` registers
       { SayHello => $mref } in _activity_defs (T-act-1)
     - Test :Defn('Custom') overrides the name (T-act-2)
     - Test two :Defn methods on one class both register (T-act-3)
     - Test FunctionDefinition->new(name, code) registers (T-act-4)
     - Test duplicate activity type names in a worker registry raise
       Argument (T-wkr-2, registry-level)
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Activity.pm, Activity/Definition.pm,
     Activity/Attributes.pm (:ATTR(CODE,BEGIN) per §10.1 constraints),
     Activity/FunctionDefinition.pm
   - Create the registry builder (used by Worker in P2.2) in
     sdk/lib/Temporalio/Worker/ActivityRegistry.pm
3. Verify: cd sdk && prove -lj4 t/unit/activity_definition.t
```

### Step P2.2: Worker construction + validate

**NOTE**: Spec §8.1–§8.2 steps 1–2. Reuses P0.10's WorkerOptions
marshalling for real.

```text
1. RED: Write worker construction tests first:
   - Create sdk/t/unit/worker_new.t:
     - Test Worker->new builds registries correctly (T-wkr-1)
     - Test kwargs → WorkerOptions mapping per spec §8.1 (echo via the
       P0.10 debug function: versioning None{build_id}, FixedSize tuner
       from max_concurrent_*, task_types wf+activities only)
   - Create sdk/t/integration/worker_new.t (DevServer-backed):
     - Test worker_new + validate succeeds against a real connection
     - Test worker against a fresh task queue constructs and shuts down
       cleanly (T-wkr-5 shape)
2. GREEN: Write MINIMAL code:
   - Attach worker_new/worker_validate/worker_free/worker_initiate_shutdown/
     worker_finalize_shutdown in Core::FFI
   - Create sdk/lib/Temporalio/Worker.pm (construction + validate + shutdown
     plumbing; run loops land in P2.4/P3.6)
3. Verify: cd sdk && prove -lj4 t/unit/worker_new.t t/integration/worker_new.t
```

### Step P2.3: Activity::Context + heartbeat

**NOTE**: Spec §9.3. `dynamically` (NOT `local`) across await — hard
requirement, see §16.1. Heartbeat wraps coresdk.ActivityHeartbeat.

```text
1. RED: Write context tests first:
   - Create sdk/t/unit/activity_context.t:
     - Test Temporalio::Activity::context() outside an activity raises
       (NoContext/Argument per spec)
     - Test context() inside a dispatched body returns the right ctx even
       across an await point (regression for the local-vs-dynamically panic)
     - Test heartbeat(@details) encodes payloads, applies codec chain, wraps
       coresdk.ActivityHeartbeat{task_token, details}, calls the sync FFI
       (spy), and raises Exception::Heartbeat on non-null return (T-act-7 unit)
     - Test ->cancellation is a Temporalio::Cancellation
2. GREEN: Write MINIMAL code:
   - Attach worker_record_activity_heartbeat in Core::FFI
   - Create sdk/lib/Temporalio/Activity/Context.pm per spec §9.3
3. Verify: cd sdk && prove -lj4 t/unit/activity_context.t
```

### Step P2.4: Activity poll loop (async activities)

**NOTE**: Spec §8.4 — start|cancel branch, task_token map, codec boundary.
Make the poll source injectable so unit tests feed crafted ActivityTask
protos without a server.

```text
1. RED: Write dispatch unit tests first (injected poll source):
   - Create sdk/t/unit/activity_dispatch.t:
     - Test a start task decodes input, runs the async activity, sends a
       completion with the encoded result (T-act-5)
     - Test a die in the body produces a completion failure with cause type
       preserved (T-act-8, ApplicationError type 'X')
     - Test a cancel task cancels the running activity's token; activity
       awaiting ->cancellation completes cancelled (T-act-9)
     - Test cancel for an unknown task_token logs + drops
     - Test codec decode applied to start.input/heartbeat_details and encode
       applied to completion payloads (mock codec records calls)
     - Test the running-activities map adds on start, removes on completion
2. GREEN: Write MINIMAL code:
   - Attach worker_poll_activity_task/worker_complete_activity_task in
     Core::FFI
   - Create sdk/lib/Temporalio/Worker/ActivityDispatcher.pm +
     sdk/lib/Temporalio/Worker/PollLoop.pm (activity loop only) per §8.4
3. GREEN: Wire Worker->run to start the activity poll loop and honor
   initiate/finalize shutdown (T-wkr-4: shutdown mid-run returns; second
   shutdown is a no-op — add to t/unit/activity_dispatch.t with the
   injected source returning the shutdown sentinel)
4. REFACTOR: Completion-building (success/failure/cancelled) into one
   builder module shared later by the workflow side
5. Verify: cd sdk && prove -lj4 t/unit/activity_dispatch.t && prove -lj4 t
```

### Step P2.5: Sync activity fork pool

**NOTE**: Spec §9.4 — IO::Async::Function, init_code FD hygiene, heartbeat
pipe relay.

```text
1. RED: Write pool tests first:
   - Create sdk/t/unit/activity_pool.t:
     - Test a sync activity body runs in a child and returns its result
       (T-act-6)
     - Test child closes inherited parent FDs — reading the parent's eventfd
       from the child fails EBADF (T-act-10)
     - Test heartbeat from the child arrives at the parent's FFI heartbeat
       call (pipe relay, spy on parent side)
     - Test cooperative cancellation: parent sends cancel message; child's
       ctx->cancellation->is_cancelled goes true
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Activity/Pool.pm per spec §9.4 (init_code +
     _child_dispatch as specified)
   - Route sync-declared activities to the pool in ActivityDispatcher
3. REFACTOR: Serialize the cross-fork invocation struct once (args already
   converted to plain scalars — no protobuf in the child)
4. Verify: cd sdk && prove -lj4 t/unit/activity_pool.t && prove -lj4 t
   Phase 2 acceptance (spec §11) green at unit level; the cross-SDK
   integration scenario is superseded by Phase 3's all-Perl end-to-end.
```

---

## Phase 3 — Workflows

### Step P3.1: Workflow::Definition + attribute registration

**NOTE**: Spec §10.1 — the four spike-verified constraints are design law.

```text
1. RED: Write registration tests first:
   - Create sdk/t/unit/workflow_definition.t:
     - Test :Run registers; workflow type defaults to class basename;
       :Run('Custom') overrides (spec §8.6)
     - Test :Signal/:Query/:Update with and without explicit names populate
       _workflow_defs correctly ($data arrayref-or-undef normalization)
     - Test :Init registers; two :Run methods raise at registration
     - Test duplicate workflow type names in a worker registry raise
       Argument (T-wkr-2 workflow side)
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Workflow.pm (loader),
     Workflow/Definition.pm, Workflow/Attributes.pm — :ATTR(CODE,BEGIN),
     handlers inside the base class per §10.1 constraints
   - Create sdk/lib/Temporalio/Worker/WorkflowRegistry.pm
3. Verify: cd sdk && prove -lj4 t/unit/workflow_definition.t
```

### Step P3.2: Temporalio::Workflow::Future

**NOTE**: Spec §10.3 "Workflow::Future" block. Pure Future subclass — no FFI.

```text
1. RED: Write workflow-future tests first:
   - Create sdk/t/unit/workflow_future.t:
     - Test manual resolve runs awaiting continuations synchronously
     - Test on_cancel hooks fire in reverse-registration order on ->cancel
     - Test is_workflow_future is true
2. GREEN: Create sdk/lib/Temporalio/Workflow/Future.pm per spec §10.3
3. Verify: cd sdk && prove -lj4 t/unit/workflow_future.t
```

### Step P3.3: Runner core + replay harness (trivial workflow completes)

**NOTE**: Spec §10.3 steps 1–2, 5–7 with no pending-Future jobs yet; §10.6
harness. Runner context via Syntax::Keyword::Dynamically (§10.2).

```text
1. RED: Write replay-harness tests first:
   - Create sdk/t/replay/runner_basics.t using a new harness:
     - Test a workflow whose :Run returns a constant: one activation with
       start_workflow job → exactly one CompleteWorkflowExecution command
       with the converted result (T-wf-11 shape)
     - Test Temporalio::Workflow::now/time return the activation timestamp;
       is_replaying reflects the activation flag
     - Test calling Temporalio::Workflow::info outside a body raises
       Workflow::NoRunner
     - Test the RNG is seeded from the start job's randomness_seed (two
       runners, same seed → same sequence — T-wf-10)
2. GREEN: Write MINIMAL code:
   - Create sdk/lib/Temporalio/Workflow/Runner.pm: process_activation
     skeleton (job ordering sets per §10.3 step 3; start job; pump; command
     buffer; completion build), Workflow/Context plumbing via `dynamically`
   - Create sdk/lib/Temporalio/Workflow/Commands.pm (command builders)
   - Create sdk/lib/Temporalio/Test/WorkflowReplay.pm per spec §10.6
     (push_activation returning decoded commands)
3. REFACTOR: Pump loop per §10.3 pump semantics — no IO::Async inside
4. Verify: cd sdk && prove -lj4 t/replay/runner_basics.t
```

### Step P3.4: execute_activity + ResolveActivity

**NOTE**: Spec §10.2 execute_activity kwargs, §10.3 seq allocation.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/activities.t:
     - Test start job → ScheduleActivity command with right type/args/
       timeouts/seq=1 (T-wf-1)
     - Test ResolveActivity{seq:1, result} resumes the await; completion is
       CompleteWorkflowExecution with the activity's result (T-wf-2)
     - Test ResolveActivity failure → Exception::Activity raised at the
       await site with cause->type populated (T-wf-7)
     - Test two concurrent execute_activity calls get seq 1 and 2;
       out-of-order resolution resolves the right Futures
2. GREEN: Implement Temporalio::Workflow::execute_activity/start_activity in
   sdk/lib/Temporalio/Workflow.pm + pending_activities map + ResolveActivity
   job handling in Runner.pm
3. Verify: cd sdk && prove -lj4 t/replay/activities.t
```

### Step P3.5: Timers — start_timer / sleep / FireTimer

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/timers.t:
     - Test start_timer(60) emits StartTimer{seq:1, 60s}; FireTimer{seq:1}
       resumes; post-sleep commands appear (T-wf-6)
     - Test sleep() is an alias producing identical commands
     - Test cancelling a timer Future emits CancelTimer (Workflow::Future
       on_cancel path)
2. GREEN: Implement start_timer/sleep + pending_timers + FireTimer handling
3. Verify: cd sdk && prove -lj4 t/replay/timers.t
```

### Step P3.6: Workflow poll loop + dispatcher cache + eviction

**NOTE**: Spec §8.3 (incl. eviction fast path, codec boundary, serial-v0.1
note) and §10.3 RemoveFromCache. Injectable poll source for unit tests.

```text
1. RED: Write dispatcher/loop tests first (injected poll source):
   - Create sdk/t/unit/workflow_poll_loop.t:
     - Test activations route by run_id; new run creates a runner; cached
       run reuses it
     - Test eviction-only activation → empty successful completion, runner
       dropped, no workflow code invoked (T-wf-14)
     - Test RemoveFromCache combined with other jobs applies eviction last
     - Test codec decode on inbound activation payloads and encode on
       outbound completion payloads (mock codec records calls)
     - Test shutdown sentinel (undef) exits the loop
2. GREEN: Write MINIMAL code:
   - Attach worker_poll_workflow_activation/worker_complete_workflow_activation
     in Core::FFI
   - Create sdk/lib/Temporalio/Worker/WorkflowDispatcher.pm; extend
     PollLoop.pm with the workflow loop per §8.3 steps 1–10
   - Implement RemoveFromCache teardown in Runner.pm
3. GREEN: Wire Worker->run to start both loops; both exit on shutdown
4. Verify: cd sdk && prove -lj4 t/unit/workflow_poll_loop.t && prove -lj4 t
```

### Step P3.7: Completion outcomes — cancel / fail / task-fail / continue-as-new

**NOTE**: Spec §10.3 step 6 decision table — the de facto Temporal spec.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/completion_outcomes.t:
     - Test CancelWorkflow job → pending activity rejected Cancelled →
       escape → CancelWorkflowExecution command (T-wf-12)
     - Test plain `die "boom"` → WorkflowActivationCompletion.failed (task
       failure), workflow NOT failed (T-wf-15a)
     - Test ApplicationError escape → FailWorkflowExecution (T-wf-15b)
     - Test a non-Temporal class listed in workflow_failure_exception_types
       → FailWorkflowExecution (T-wf-15c)
     - Test continue_as_new → ContinueAsNewWorkflowExecution with args and
       policies (T-wf-8)
     - Test unknown seq resolution → non-determinism handling honors
       nondeterminism_as_workflow_fail (T-wf-13)
2. GREEN: Implement the outcome decision table + continue_as_new +
   CancelWorkflow handling in Runner.pm / Workflow.pm
3. Verify: cd sdk && prove -lj4 t/replay/completion_outcomes.t
```

### Step P3.8: Determinism primitives — random / logger / patches

**NOTE**: Spec §10.4. now/time/seed landed in P3.3; this adds the rest.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/determinism.t:
     - Test UpdateRandomSeed job re-seeds: sequence changes deterministically
     - Test logger output suppressed while is_replaying, resumes after
       (T-wf-9, captured via a test Log::Any adapter)
     - Test NotifyHasPatch records the patch id in workflow info
2. GREEN: Implement Temporalio::Workflow::random (Math::Random::ISAAC::XS),
   logger gating, NotifyHasPatch/UpdateRandomSeed handlers
3. Verify: cd sdk && prove -lj4 t/replay/determinism.t
```

### Step P3.9: End-to-end — Perl workflow + Perl activity + hello-world

**NOTE**: Phase 3 acceptance gate (spec §11). Everything integrates here.

```text
1. RED: Write the end-to-end integration test first:
   - Create sdk/t/integration/end_to_end.t (DevServer-backed):
     - Test: start GreetingWorkflow via the client; a Perl worker running
       both the workflow and SayHello activity completes it; result eq
       "Hello, Alice!" (T-cli-result-1 + Phase 3 gate)
     - Test: workflow with a 1s sleep completes (timer path end-to-end)
     - Test: activity failure propagates — result raises WorkflowFailure
       with cause Activity → cause Application(type)
2. GREEN: Fix whatever the integration shakes out — no new features
3. Create sdk/examples/hello-world/ (workflow.pm, activity.pm, worker.pl,
   starter.pl) runnable against `temporal server start-dev`
4. REFACTOR: Promote any test-only glue worth keeping into Temporalio::Test::*
5. Verify: cd sdk && prove -lj4 t — Phase 3 acceptance (spec §11) green
```

---

## Phase 4 — Signals & queries

### Step P4.1: Signal handling in the runner

**NOTE**: Spec §10.3 SignalWorkflow job — sync and async handlers, pending
queue for not-yet-registered handlers, in-progress tracking.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/signals.t:
     - Test signal job before :Run completes mutates state visible to the
       run continuation (T-wf-3; ordering set (b) before (c))
     - Test unknown signal with no dynamic handler queues; a later-registered
       handler drains the queue
     - Test an async signal handler's Future is tracked and pumped to
       completion before CompleteWorkflowExecution is emitted
2. GREEN: Implement SignalWorkflow handling + pending_signals +
   in-progress-handlers set in Runner.pm
3. Verify: cd sdk && prove -lj4 t/replay/signals.t
```

### Step P4.2: Query handling

**NOTE**: Spec §10.3 QueryWorkflow — synchronous, queries ordered last.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/queries.t:
     - Test query during a pending activity returns current state without
       disturbing the run Future (T-wf-4)
     - Test a dying query handler produces a query failure response, not a
       workflow/task failure
     - Test queries are processed after other jobs in the same activation
2. GREEN: Implement QueryWorkflow handling + RespondToQuery command
3. Verify: cd sdk && prove -lj4 t/replay/queries.t
```

### Step P4.3: wait_condition

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/wait_condition.t:
     - Test predicate flipped by a signal resumes the awaiting continuation
       in the same activation (T-wf-5)
     - Test timeout kwarg: FireTimer for the condition's timer rejects the
       wait with Timeout semantics per other SDKs
     - Test predicates are re-checked each pump iteration until stable
2. GREEN: Implement Temporalio::Workflow::wait_condition per spec §10.2
3. Verify: cd sdk && prove -lj4 t/replay/wait_condition.t
```

### Step P4.4: Client signal/query end-to-end + example

**NOTE**: Phase 4 acceptance gate (spec §11).

```text
1. RED: Write integration tests first:
   - Create sdk/t/integration/signals_queries.t (DevServer-backed):
     - Test $handle->signal('changeGreeting', ['hi']) is processed by a Perl
       worker (T-cli-signal-1)
     - Test $handle->query('current_greeting') returns the decoded value
       (T-cli-query-1)
     - Test a query with reject_condition against a terminated workflow
       raises QueryRejected (T-cli-query-2)
2. GREEN: Fix integration fallout; no new features
3. Create sdk/examples/greet-with-signal/ mirroring spec §10.1's example
4. Verify: cd sdk && prove -lj4 t — Phase 4 acceptance (spec §11) green
```

---

## Phase 5 — Hardening for v0.1

### Step P5.1: Cancellation end-to-end

**NOTE**: Spec §11 Phase 5 — client → workflow → activity.

```text
1. RED: Write integration tests first:
   - Create sdk/t/integration/cancellation.t (DevServer-backed):
     - Test $handle->cancel → workflow receives CancelWorkflow → in-flight
       activity's token cancels → result raises WorkflowFailure with cause
       Cancelled (T-cli-cancel-1 + T-wf-12 + T-act-9 end-to-end)
     - Test 'abandon' cancellation_type leaves the activity running while
       the workflow cancels
2. GREEN: Fix propagation gaps (likely: RequestCancelActivity command from
   Workflow::Future on_cancel; worker-side token wiring)
3. Verify: cd sdk && prove -lj4 t/integration/cancellation.t
```

### Step P5.2: RPC special-case audit + failure-path integration

```text
1. RED: Write integration tests first:
   - Create sdk/t/integration/error_paths.t (DevServer-backed):
     - Test workflow failing with ApplicationError(type 'X') → client result
       raises WorkflowFailure with cause Application type 'X' (T-cli-result-2)
     - Test continue-as-new follow_runs both ways (T-cli-result-4)
     - Test transient UNAVAILABLE during result long-poll is retried
       (T-cli-result-5; restart the dev server mid-poll or mock at
       _rpc_call level)
2. GREEN: Fix mapping/conversion fallout; no new features
3. Verify: cd sdk && prove -lj4 t/integration/error_paths.t
```

### Step P5.3: POD + author tests + README

```text
1. RED: Create sdk/xt/pod-coverage.t (100% POD on public Temporalio::*
   classes) and sdk/xt/pod-syntax.t — they fail against current code
2. GREEN: Write hand-written POD (no Pod::Weaver, per spec §16.7) for every
   public class: synopsis, description, methods with signatures, exceptions
3. Write README.md (repo root + sdk/): install via cpanm git+, Perl 5.38
   floor + RHEL/macOS notes from spec §14, quickstart from hello-world
4. Verify: cd sdk && prove -lj4 xt t
```

### Step P5.4: CI matrix

```text
1. Create .github/workflows/ci.yml per spec §14: OS × Perl matrix, Rust
   stable, ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH against a pinned sdk-rust
   checkout, dzil test on all three dists, xt stage, integration stage,
   cargo/cpanm caches, allow-failure Windows job
2. Verify: CI green on a feature-branch push (do NOT merge to main; Mason
   merges)
```

### Step P5.5: v0.1.0 release prep

```text
1. RED: Add sdk/t/unit/version.t asserting $Temporalio::SDK::VERSION,
   dist.ini versions, and Alien::Temporalio::Core->version pin agree
2. GREEN: Set versions: Temporalio-SDK 0.1.0, Alien-Temporalio-Core
   tracking the pinned sdk-core tag, Alien-Temporalio-PerlBridge 0.1.0
3. Update spec.md §11 statuses + this plan's Current Status; final
   `prove -lj4 t xt` + cargo test sweep
4. Verify: full suite green; tag list prepared for Mason (no pushes to main)
```

---

# Part II — v0.2 feature parity

These phases bring the SDK to parity with the Python/Ruby SDKs. Each step
derives from a detailed spec contract (spec.md §18+) and is appended here
so `/bpe:goal` / `/bpe:execute-plan` pick up at the first unchecked item.
Phases 0–5 above remain the completed v0.1 record.

## Phase 6 — Workflow feature parity

### Step P6.1: Child workflows (spec §18)

**NOTE**: §18 — two-stage resolution (start then result), separate seq
space, explicit `$handle->cancel`, RNG-derived default id. Mirror the
execute_activity pattern (P3.4). Enums are lowercase strings mapped in the
Runner (§18.1).

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/child_workflows.t and fixtures in sdk/t/lib/WfDef/:
     - start_child_workflow emits one StartChildWorkflowExecution (seq=1,
       type, id, parent task_queue, parent_close_policy=1,
       cancellation_type=2, reuse=allow_duplicate, converted args); body
       parks, no completion command (T-child-1)
     - ResolveChildWorkflowExecutionStart{succeeded{run_id}} resolves start;
       first_execution_run_id==run_id; start-only workflow completes,
       execute workflow stays parked (T-child-2)
     - ResolveChildWorkflowExecution{completed{result}} resumes execute;
       workflow completes with converted result (T-child-3)
     - result failed{failure} → Exception::ChildWorkflow (cause=mapped)
       (T-child-4)
     - start failed{WORKFLOW_ALREADY_EXISTS} → WorkflowAlreadyStarted on the
       start await; start cancelled{failure} → Cancelled (T-child-5/6)
     - $handle->cancel emits CancelChildWorkflowExecution{seq:1}; abandon
       emits none (T-child-7)
     - two children seq 1,2 (separate space); out-of-order resolve
       (T-child-8); $handle->signal uses child_workflow_id arm (T-child-9)
     - enum string mapping + bad string dies at scheduling time (T-child-10)
     - CancelWorkflow propagation cancels a pending child handle (T-child-11)
     - omitted id is deterministic across re-run (T-child-12)
2. GREEN: Implement in sdk/lib/Temporalio/Workflow.pm
   (execute_child_workflow/start_child_workflow), new
   sdk/lib/Temporalio/Workflow/ChildWorkflowHandle.pm,
   Commands.pm builders (start_child_workflow, cancel_child_workflow),
   and Runner.pm: $child_workflow_seq_counter, %pending_child_workflows,
   _apply_resolve_child_workflow_start / _apply_resolve_child_workflow,
   enum maps, RNG-derived default id; extend _apply_cancel_workflow to
   cancel pending child handles.
3. RED: Add integration test sdk/t/integration/child_workflows.t
   (skip_all without dev server): parent execute_child_workflow returns
   child value; signal child via handle; failing child → ChildWorkflow
   (T-child-13).
4. GREEN: wire until green against the dev server.
5. REFACTOR: factor the two-future handle resolution if it duplicates the
   activity resolve path.
6. Verify: cd sdk && prove -lj4 t
```

### Step P6.2: Workflow updates (spec §19)

**NOTE**: §19 — two-phase (sync read-only validator, then async tracked
handler). Reuse %in_progress_handlers gating and the set-1 job ordering
(Runner.pm:595). :Update/:UpdateValidator already parse (Definition.pm).
Add Exception::WorkflowUpdateFailed. Client half mirrors signal/query.

```text
1. RED: Write workflow-side replay tests first:
   - Create sdk/t/replay/updates.t and fixtures in sdk/t/lib/WfDef/:
     - accepted update (non-mutating validator + sync handler) → buffer is
       exactly [UpdateResponse.accepted, completed{result}] with the right
       protocol_instance_id (T-upd-1)
     - validator throws → single rejected{failure}, no accepted, state
       untouched (T-upd-2)
     - no validator / run_validator:false → accepted unconditionally
       (T-upd-3)
     - async handler awaiting an activity: accepted first activation,
       workflow not completed while handler pending, completed on resolve
       (T-upd-4)
     - handler ApplicationError post-accept → rejected{failure}, workflow
       not failed (T-upd-5); plain die post-accept → workflow task failure
       (T-upd-6)
     - DoUpdate in init activation buffered then dispatched after init
       (T-upd-7); unknown name no dynamic → immediate rejected (T-upd-8)
     - dynamic handler gets ($name,@args), not validated (T-upd-9);
       validator issuing a command → workflow task failure (T-upd-10)
     - replay run_validator:false reproduces accepted/completed (T-upd-11)
2. GREEN: Add do_update to _apply_job dispatch + set 1 of _ordered_job_sets;
   implement _apply_do_update (lookup, read-only validator guard, accept,
   tracked async handler, UpdateResponse) in Runner.pm; UpdateResponse
   builder in Commands.pm; buffer-then-drain for pre-instance updates.
   ALSO (M1): relax the existing v0.1 hard completion-gate (Runner.pm:1034) to
   warn-and-complete on unfinished handlers (parity with sdk-python/ruby) +
   expose Temporalio::Workflow::all_handlers_finished; update the affected
   v0.1 signal test.
3. RED: Write client-side integration tests:
   - Create sdk/t/integration/updates.t (skip_all without dev server):
     execute_update returns result (T-cli-update-1); start_update
     wait_for_stage=>'accepted' + ->result polls to completion
     (T-cli-update-2); validator-rejected → WorkflowUpdateFailed,
     workflow running (T-cli-update-3); handler ApplicationError →
     WorkflowUpdateFailed (T-cli-update-4); 'admitted' → Exception::Argument
     pre-RPC (T-cli-update-5); update on closed workflow → §7.5 mapping
     (T-cli-update-6); explicit update_id round-trips (T-cli-update-7)
4. GREEN: Add WorkflowHandle->execute_update/start_update, new
   sdk/lib/Temporalio/Client/WorkflowUpdateHandle.pm (UpdateWorkflowExecution
   retry-to-accepted + PollWorkflowExecutionUpdate), new
   sdk/lib/Temporalio/Exception/WorkflowUpdateFailed.pm; wait_for_stage map
   with 'admitted' guard.
5. Verify: cd sdk && prove -lj4 t
```

### Step P6.3: External workflow handles (spec §20)

**NOTE**: §20 — in-workflow signal/cancel of another workflow via commands
(not RPCs). Two independent seq counters; namespace from
Workflow::info; no bespoke exception (from_failure verbatim).

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/external_workflow.t and fixtures in
     sdk/t/lib/WfDef/:
     - get_external_workflow_handle outside a body → NoRunner; inside →
       handle echoing workflow_id/run_id, no command emitted (T-ext-1)
     - await $h->signal('go', args=>['x']) emits one
       SignalExternalWorkflowExecution (seq:1, workflow_execution arm:
       namespace=run's, workflow_id, run_id empty; signal_name; encoded
       args); child_workflow_id arm unset (T-ext-2)
     - ResolveSignalExternalWorkflow{seq:1} no failure → done (T-ext-3);
       with application "not found" failure → Exception::Application
       (T-ext-4)
     - await $h->cancel emits RequestCancelExternalWorkflowExecution
       (seq:1, same workflow_execution, reason unset) (T-ext-5);
       ResolveRequestCancelExternalWorkflow done / failure→Application
       (T-ext-6)
     - independent seq spaces: two signals (seq 1,2) + one cancel (seq 1);
       out-of-order resolve (T-ext-7); explicit run_id threaded (T-ext-8)
     - cancelling an in-flight signal frame emits CancelSignalWorkflow{seq}
       and does not pre-emptively raise; subsequent Resolve* settles
       (T-ext-9)
2. GREEN: Implement Temporalio::Workflow::get_external_workflow_handle, new
   sdk/lib/Temporalio/Workflow/ExternalWorkflowHandle.pm, Commands.pm
   builders (signal_external_workflow_execution,
   request_cancel_external_workflow_execution, cancel_signal_workflow),
   and Runner.pm: two seq counters, pending maps,
   _apply_resolve_signal_external_workflow /
   _apply_resolve_request_cancel_external_workflow, namespace injection
   from info.
3. RED: Add integration test sdk/t/integration/external_workflow.t
   (skip_all without dev server): workflow B signals then cancels A by id;
   A observes the signal and reaches cancelled; non-existent id →
   Application (T-ext-10).
4. GREEN: wire until green.
5. Verify: cd sdk && prove -lj4 t — **Phase 6 acceptance: workflow parity
   (child workflows + updates + external handles) green**
```

## Phase 7 — Activity feature parity

### Step P7.1: Local activities (spec §21)

**NOTE**: §21 — analog of execute_activity (P3.4) sharing the activity seq
space/%pending_activities. New: ScheduleLocalActivity/RequestCancelLocalActivity
commands + the backoff→server-timer loop (runner-owned, resolved D1). Worker
side unchanged — core runs the LA.

```text
1. RED: Write replay tests first:
   - Create sdk/t/replay/local_activities.t + WfDef fixtures:
     - complete_immediately: one ScheduleLocalActivity, value in same WFT
       (T-local-1); serial three commands (T-local-3); concurrent share
       %pending_activities (T-local-4)
     - retry_on_error: only terminal failure reaches lang (T-local-5);
       non_retryable from activity / in options (T-local-6/7)
     - backoff_with_persistent_timer: ResolveActivity{backoff} → StartTimer
       → re-schedule new seq + attempt + original_schedule_time; outer await
       unaffected (T-local-9)
     - cancel_try_cancel / cancel_wait_completed / cancel_abandon
       (T-local-10/11/12); cancel_failing backing-off LA → CancelTimer
       (T-local-13)
     - shutdown tolerates late LA resolves without non-determinism
       (T-local-14/15)
2. GREEN: Workflow.pm execute_local_activity/start_local_activity;
   Runner.pm schedule_local_activity (shared activity seq) + backoff branch
   in _apply_resolve_activity + runner-owned backoff loop (StartTimer +
   re-schedule); Commands.pm schedule_local_activity +
   request_cancel_local_activity.
3. REFACTOR: share the resolve/cancel paths with regular activities where
   they coincide.
4. Verify: cd sdk && prove -lj4 t
```

### Step P7.2: Async activity completion (spec §22)

**NOTE**: §22 — client-side AsyncActivityHandle (token-or-id union) + the
8 Respond/Record RPCs + worker-side complete_async. heartbeat raises
AsyncActivityCancelled on cancel/pause/reset. Detect-only: keyword-only
factory; package verb + public CompleteAsync class.

```text
1. RED: Write tests first:
   - sdk/t/unit/async_activity.t: arg-validation (token+id / wf-without-act /
     neither → Argument, T-asyncact-8); request building per RPC by explicit
     field number
   - sdk/t/integration/async_activity.t (skip without dev server):
     complete/fail/report_cancellation/heartbeat by token and by id
     (T-asyncact-1..5,9); heartbeat cancel/pause/reset → AsyncActivityCancelled
     (T-asyncact-6); complete_async end-to-end (T-asyncact-7)
2. GREEN: Client->async_activity_handle + Client/AsyncActivityHandle.pm
   (heartbeat/complete/fail/report_cancellation via _rpc_call);
   Exception/Activity/CompleteAsync.pm + AsyncActivityCancelled.pm;
   Temporalio::Activity::complete_async; ActivityDispatcher reports
   WillCompleteAsync.
3. Verify: cd sdk && prove -lj4 t
```

### Step P7.3: Eager start (spec §23)

**NOTE**: §23 — eager workflow start is DETECT-ONLY (request flag already
wired; add eagerly_started accessor; core owns dispatch). Eager activity:
disable_eager_activity_execution (schedule_activity flag) +
no_remote_activities (bridge enable_remote_activities).

```text
1. RED: Write tests first:
   - sdk/t/unit/eager.t: request_eager_start sets request_eager_execution
     (T-eager-1); eagerly_started true/false off the response (T-eager-2/3,
     unit with a stubbed response); no_remote_activities → bridge
     enable_remote_activities=0 (T-eager-4);
     disable_eager_activity_execution suppresses the eager flag on
     schedule_activity (T-eager-6)
   - sdk/t/integration/eager.t (skip without dev server / skip when server
     eager disabled): T-eager-2 live; T-eager-5 schedule-to-start timeout on
     a no_remote_activities worker
2. GREEN: WorkflowHandle->eagerly_started; Worker.pm
   disable_eager_activity_execution + no_remote_activities →
   enable_remote_activities; thread the eager flag through schedule_activity.
3. Verify: cd sdk && prove -lj4 t
```

### Step P7.4: In-workflow upsert search-attributes & memo (spec §24)

**NOTE**: §24 — typed-only SA (value_set/value_unset on SearchAttributeKey),
memo hashref with undef-deletes. Commands UpsertWorkflowSearchAttributes
(tag 18) / ModifyWorkflowProperties (tag 19); update info view; pre-convert.

```text
1. RED: Write replay tests first:
   - sdk/t/replay/upsert.t + WfDef fixtures: value_set → one command with
     indexed_fields (T-upsert-1); value_unset → null Payload (T-upsert-2);
     sequential upserts update info->{search_attributes} correctly, no
     BinaryChecksums (T-upsert-3); start-time SAs in info (T-upsert-4);
     upsert_memo set/delete (T-upsert-5/6); empty → no command (T-upsert-7);
     conversion failure before buffer (T-upsert-8); outside body → NoRunner
     (T-upsert-9)
2. GREEN: Workflow.pm upsert_search_attributes/upsert_memo; Commands.pm two
   builders; Runner.pm conversion+buffer+info-view update;
   SearchAttributeKey value_set/value_unset.
3. Verify: cd sdk && prove -lj4 t — **Phase 7 acceptance: activity parity
   (local activities, async completion, eager, upsert) green**
```

## Phase 8 — Scheduling

### Step P8.1: Schedule data classes + Client methods (spec §25)

**NOTE**: §25 — purely client-side. Data classes with load-bearing proto
remaps (policy↔policies, calendars↔structured_calendar, every↔interval,
note↔notes); default calendar ranges injected; Range inclusive/inclusive.

```text
1. RED: Write unit tests first:
   - sdk/t/unit/schedule_types.t: each data class round-trips _to_proto/
     _from_proto with the correct field remaps; default ranges injected
     (second=[0], day_of_month=[1..31]); Range inclusive/inclusive no +1;
     three inclusivity rules (Range, spec.start_time, backfill exclusive)
     (T-sched-unit); OverlapPolicy string→enum
   - sdk/t/unit/schedule_request.t: create_schedule builds CreateScheduleRequest
     (initial_patch only when trigger/backfills; overlap from schedule policy);
     limited/remaining invariant → Argument; action rejects
     workflow_id_reuse_policy/cron_schedule kwargs
2. GREEN: Schedule.pm umbrella + Schedule/{Schedule,Spec,Calendar,Range,
   Interval,State,Policy,Action,Backfill,Update,Description,Info,
   ListDescription}.pm; Client->create_schedule/get_schedule_handle/
   list_schedules; Client/ScheduleListIterator.pm;
   Exception/ScheduleAlreadyRunning.pm.
3. Verify: cd sdk && prove -lj4 t/unit
```

### Step P8.2: ScheduleHandle ops + integration (spec §25)

```text
1. RED: Write tests first:
   - sdk/t/unit/schedule_handle.t: describe/delete/backfill/trigger/pause/
     unpause/update build the right PatchSchedule/Update/Delete requests
     (delete has no request_id; default notes exact); backfill empty →
     Argument; update single-shot (updater invoked once; falsy → no RPC);
     duplicate create → ScheduleAlreadyRunning via stubbed ALREADY_EXISTS
     (T-sched-4)
   - sdk/t/integration/schedule.t (skip without dev server): basic
     create/describe/list/update/delete (T-sched-1); backfill (T-sched-2);
     cron round-trip (T-sched-3); pause/unpause notes (T-sched-5); trigger
     (T-sched-6); list_matching_times (T-sched-7)
2. GREEN: Client/ScheduleHandle.pm (all methods via _rpc_call); update's
   describe→updater→UpdateSchedule flow.
3. Verify: cd sdk && prove -lj4 t — **Phase 8 acceptance: schedules green**
```

## Phase 9 — Nexus

### Step P9.1: Nexus caller side (spec §26)

**NOTE**: §26 — caller mirrors the §18 child-workflow two-stage pattern
(ScheduleNexusOperation → ResolveNexusOperationStart then
ResolveNexusOperation), separate seq space. Single input Payload. Sync
(started_sync + same-activation completed) vs async (operation_token).

```text
1. RED: Write replay tests first:
   - sdk/t/replay/nexus.t + WfDef fixtures: start_operation emits one
     ScheduleNexusOperation (seq 1, single input, cancellation_type=0,
     timeouts) (T-nexus-1); started_sync + same-activation completed →
     execute result, operation_token undef (T-nexus-2); operation_token start
     + later completed (T-nexus-3/4); failed/timed_out/cancelled →
     NexusOperation cause Application/Timeout/Cancelled (T-nexus-5/6); start
     failed fails start await (T-nexus-7); cancel emits
     RequestCancelNexusOperation / abandon none / pre-scheduled Cancelled
     (T-nexus-8); unknown seq → non-determinism (T-nexus-9)
2. GREEN: Workflow.pm create_nexus_client; Workflow/NexusClient.pm +
   NexusOperationHandle.pm; Commands.pm schedule_nexus_operation +
   request_cancel_nexus_operation; Runner.pm nexus seq space + pending maps +
   _apply_resolve_nexus_operation_start/_apply_resolve_nexus_operation +
   cancel propagation; NexusOperationCancellationType map.
3. Verify: cd sdk && prove -lj4 t
```

### Step P9.2: Nexus handler side (spec §26)

**NOTE**: §26 handler side (Python-reference) — reimplement the nexusrpc
slice natively. Attribute pattern :NexusService/:SyncOperation/
:WorkflowRunOperation. Dispatcher mirrors the activity dispatcher.

```text
1. RED: Write tests first:
   - sdk/t/unit/nexus_definition.t: :NexusService/:SyncOperation/
     :WorkflowRunOperation register service+operations in the registry; four
     §10.1 constraints hold (T-nexus-11)
   - sdk/t/integration/nexus.t (skip without dev server + endpoint): full
     sync_success — execute_operation against My::NexusService on the same
     worker returns "Hello, world!"; history Scheduled+Completed, NO Started
     (T-nexus-10/12); workflow-run op start → Async{token}, cancel cancels
     backing workflow (T-nexus-13); handler error → NexusHandler with right
     type; OperationError → failure-carrying response (T-nexus-14)
2. GREEN: Nexus.pm + Nexus/{Definition,OperationContext,OperationResult,
   WorkflowHandle}.pm; Worker/NexusDispatcher.pm + NexusRegistry.pm;
   Worker.pm nexus_services arg; gRPC→Nexus error-type MUST-match table.
3. Verify: cd sdk && prove -lj4 t — **Phase 9 acceptance: Nexus green**
```

## Phase 10 — Runtime, observability & worker hardening

### Step P10.1: Interceptor framework (spec §27)

**NOTE**: §27 — four surfaces (client outbound, worker activity/workflow
inbound, workflow outbound) as :isa base classes; chain folds first-listed
outermost; args/headers-writable Inputs; workflow interceptors deterministic.

```text
1. RED: Write tests first (sdk/t/unit/interceptors.t + replay fixtures):
   - client outbound start_workflow injects header, workflow inbound reads it
     (T-icpt-1); client_interceptor compliance: start_workflow_update
     increments args[0] (T-icpt-2); first-listed outermost (T-icpt-3);
     activity/workflow inbound wrapping (T-icpt-4,6); workflow outbound
     execute_activity header → activity inbound (T-icpt-5); worker inherits
     client interceptors (T-icpt-7); no-op default delegation (T-icpt-8);
     exception rejects Future (T-icpt-9); replay-determinism (T-icpt-10)
2. GREEN: Client/Interceptor.pm + Client/OutboundInterceptor.pm;
   Worker/Interceptor.pm + Activity/Workflow Inbound/Outbound base classes +
   Input classes; chain-build + install at Client/Worker/Runner sites;
   interceptors => [] args on Client->connect and Worker->new.
3. Verify: cd sdk && prove -lj4 t
```

### Step P10.2: OpenTelemetry tracing interceptor (spec §27)

**NOTE**: §27.4 — TracingInterceptor consuming client+activity+workflow roles;
header _tracer-data; OTel soft dep + W3C fallback; needs the
durable_scheduler_disabled Runner primitive; replay-safe completed spans.

```text
1. RED: Write tests first (sdk/t/unit/tracing.t, skip_all without OTel):
   - end-to-end span tree via in-memory exporter (T-trace-1); header key +
     carrier (T-trace-2); always_create_workflow_spans (T-trace-3); span-name
     table (T-trace-4); replay safety, no span on replay except query
     (T-trace-5); CompleteWorkflow failure span, benign ApplicationError not
     ERROR (T-trace-6); context survives await (T-trace-7); skip without OTel
     (T-trace-8); signal/query/update linking (T-trace-9)
2. GREEN: Contrib/OpenTelemetry/TracingInterceptor.pm; add
   Workflow::Unsafe::durable_scheduler_disabled primitive to the Runner;
   Syntax::Keyword::Dynamically context carrying; W3C fallback shim.
3. Verify: cd sdk && prove -lj4 t
```

### Step P10.3: core→Perl log forwarding (spec §28.1)

**NOTE**: §28.1 — seventh shim trampoline (kind 7) deep-copying the forwarded
log onto the existing SegQueue; no user_data → process-global registry;
duck-typed logger; keep forward_to name.

```text
1. RED: Write tests first:
   - ext/temporalio-perl-bridge cargo test: fire the kind-7 trampoline with a
     TemporalCoreForwardedLog freed immediately after return; assert deep copy
     intact under ASan (T-logfwd-3); shutdown frees N undrained kind-7 entries
     (T-logfwd-5)
   - sdk/t/unit/log_forwarding.t: forwarding undef → NULL slot (T-logfwd-1);
     core log reaches fake logger intact (T-logfwd-2); assembly-flag golden
     (T-logfwd-4); throwing logger isolated (T-logfwd-6); is_enabled gate
     (T-logfwd-7); second forwarding runtime → Argument
2. GREEN: Runtime/LogForwardingConfig.pm; LoggingConfig forward_to + to_ffi
   kind-7 pointer; shim 7th trampoline + kind-7 entry +
   temporalio_perl_bridge_forwarded_log_free + Drop; kind-7 drain builder in
   Callback.pm; process-global forwarding registry.
   (cargo test + regen header + rebuild Alien per P0.10.)
3. Verify: cargo test && cd sdk && prove -lj4 t
```

### Step P10.4: Custom metric meters (spec §28.2)

**NOTE**: §28.2 — TemporalCoreCustomMetricMeter (8 callbacks). Hybrid
threading: aggregate record_* in the Rust shim, main-thread-marshal rare
metric_new/attributes_new/free. Ruby-shaped meter interface (no MetricBuffer).

```text
0. SPIKE (do first, M3): instrument the shim trampoline with a thread-id
   check to determine whether core EVER invokes a meter callback on the main
   thread while it is inside a bridge FFI call. If it can, the marshalling
   path MUST detect "already on the main thread" and run the Perl method
   inline (no condvar) to avoid self-deadlock. Record the finding in §28.2.
1. RED: Write tests first:
   - ext/temporalio-perl-bridge cargo test: 8-thread concurrent record exact
     under shim aggregation, no off-main-thread Perl call (T-meter-7); a
     main-thread-reentrant create runs inline, no deadlock (spike guard)
   - sdk/t/unit/metric_meter.t: config sets custom_meter non-NULL others NULL
     (T-meter-1); meter+Prometheus → Argument (T-meter-2); metric_new once,
     handle identity (T-meter-3); record kinds × value types (T-meter-4);
     attribute decode incl null (T-meter-5); append-attributes superset
     (T-meter-6); throwing method no unwind/abort (T-meter-8); meter_free once
     no leak (T-meter-9)
   - sdk/t/integration/metrics.t: features/telemetry/metrics compliance
     (T-meter-10)
2. GREEN: Runtime/MetricMeter.pm; TelemetryConfig accepts a MetricMeter
   exporter + to_ffi custom_meter branch; shim 8-callback closure set +
   aggregation tables + main-thread marshalling for create/free.
   (cargo test + regen header + rebuild Alien.)
3. Verify: cargo test && cd sdk && prove -lj4 t
```

### Step P10.5: Worker versioning (spec §29.1)

**NOTE**: §29.1 — deployment-primary + legacy build-id deprecated; per-workflow
:VersioningBehavior attribute; WorkerOptions packs the versioning union
(tag 0/1/2), 464-byte tripwire unchanged.

```text
1. RED: Write tests first:
   - sdk/t/unit/worker_versioning.t: DeploymentVersion canonical-string
     round-trip + reject malformed (T-wkrver-1); constructor mutual-exclusion
     + behavior guard → Argument (T-wkrver-2); packer emits correct tag/body,
     buffer stays 464 (T-wkrver-3); :VersioningBehavior attribute parses
   - sdk/t/integration/deployment_versioning.t (skip without dev server):
     routing_pinned (T-wkrver-4); routing_auto_upgrade (T-wkrver-5);
     routing_with_override (T-wkrver-6, may need a start-time pinned override —
     flag if deferred); routing_with_ramp (T-wkrver-7, harness drives the ramp
     RPC); legacy build-id (T-wkrver-8/9) gated on ENABLE_VERSIONING_TESTS +
     the deferred build-id-compat client RPCs — skip otherwise
2. GREEN: Worker/DeploymentOptions.pm + DeploymentVersion.pm; Worker.pm
   deployment_options/use_worker_versioning; WorkerOptions versioning packers;
   :VersioningBehavior attribute on the workflow definition → activation
   completion; build_id default = MD5 of sorted %INC.
3. Verify: cd sdk && prove -lj4 t
```

### Step P10.6: Slot suppliers / worker tuner (spec §29.2)

**NOTE**: §29.2 — Tuner with 4 pools; FixedSize/ResourceBased/Custom. Custom
needs NEW shim work (reserve/try_reserve/mark/release on Tokio threads → queue
drain + complete_async_reserve).

```text
1. RED: Write tests first:
   - sdk/t/unit/tuner.t: create_fixed/create_resource_based/composite pack the
     right tags in holder order, buffer 464 (T-tuner-1/2/3); tuner +
     max_concurrent → Argument; no tuner synthesizes fixed (T-tuner-4); target
     out of (0,1] → Argument (T-tuner-7)
   - ext/temporalio-perl-bridge cargo test + sdk/t/integration: custom supplier
     reserve/release on the main thread per task (T-tuner-5); try_reserve
     undef defers (T-tuner-6)
2. GREEN: Worker/Tuner.pm + SlotSupplier/{FixedSize,ResourceBased,Custom}.pm +
   context classes; WorkerOptions ResourceBased + Custom packers; shim custom
   slot-supplier callbacks (queue drain, complete_async_reserve).
   (cargo test + regen header + rebuild Alien for the custom path.)
3. Verify: cargo test && cd sdk && prove -lj4 t
```

### Step P10.7: Autoscaling pollers (spec §29.3)

**NOTE**: §29.3 — *_poller_behavior kwargs; SimpleMaximum vs Autoscaling;
two-nullable-pointer struct; Python override semantics (legacy poll count
overrides with SimpleMaximum).

```text
1. RED: Write unit tests first (sdk/t/unit/poller_behavior.t):
   - SimpleMaximum packs (ptr,NULL) at offset 352, buffer 464 (T-poller-1);
     Autoscaling packs (NULL,ptr) with 3×u64 body (T-poller-2); explicit legacy
     poll count overrides Autoscaling with SimpleMaximum (T-poller-3);
     validation → Argument (T-poller-4)
   - sdk/t/integration smoke: worker with autoscaling pollers completes a
     trivial workflow (T-poller-5)
2. GREEN: Worker/PollerBehavior/{SimpleMaximum,Autoscaling}.pm; Worker.pm
   *_poller_behavior kwargs + override resolution; WorkerOptions poller packer
   generalized to dispatch on variant.
3. Verify: cd sdk && prove -lj4 t
```

### Step P10.8: Determinism enforcement (spec §29.4)

**NOTE**: §29.4 (NARROWED, M2) — best-effort CORE::GLOBAL:: overrides of the
TIME/ENTROPY surface ONLY (time/localtime/gmtime/rand/srand/sleep +
Time::HiRes::*); do NOT override open/fork/kill/system/exec/readpipe by
default (risk trapping IO::Async + the fork pool). Act only in workflow
context; Unsafe escape via Syntax::Keyword::Dynamically; default ON. Document
the gaps (CORE::-qualified, raw sockets not trapped).

```text
1. RED: Write replay/unit tests first (sdk/t/unit/determinism_guard.t +
   WfDef fixtures):
   - time/rand/sleep in a workflow body throw Nondeterminism; same outside a
     workflow return real values (T-det-1); Unsafe::illegal_call_tracing_disabled
     suppresses + restores (T-det-2); suppression survives await (T-det-3); SDK
     now/random never throw (T-det-4); Time::HiRes::time in a workflow throws
     (T-det-5); idempotent double-install, third-party unaffected (T-det-6);
     CORE::time AND system/open NOT trapped by default — pins the
     best-effort/narrowed boundary (T-det-7)
2. GREEN: Workflow/Unsafe.pm + Workflow/DeterminismGuard.pm (CORE::GLOBAL::
   overrides gated on $Runner::CURRENT + dynamically-scoped suppression);
   Worker kwarg to disable; self-exemption for SDK primitives.
3. Verify: cd sdk && prove -lj4 t — **Phase 10 worker-hardening green**
```

### Step P10.9: Client extras — reset + http_proxy (spec §30)

**NOTE**: §30 — thin forked reset helper; http_proxy closes the
Client.pm:589 gap (new ClientHttpConnectProxyOptions FFI record).

```text
1. RED: Write tests first:
   - sdk/t/unit/reset.t: ResetWorkflowExecutionRequest round-trip + enum
     mapping; bad enum/missing event id → Argument (T-reset-1/2)
   - sdk/t/unit/http_proxy.t: HttpConnectProxyConfig->to_ffi record non-null
     (T-proxy-1); validation incl. xor + bare-truthy → Argument (T-proxy-2);
     connect wires http_connect_proxy_options non-null/undef (T-proxy-3)
   - sdk/t/integration: reset at 2nd WFT complete, new run id, original
     terminated (T-reset-3/4/5); proxy no-auth + auth (T-proxy-4/5)
2. GREEN: WorkflowHandle->reset + Client->reset_workflow;
   Client/HttpConnectProxyConfig.pm + Core/FFI ClientHttpConnectProxyOptions
   record + wire Client.pm:589.
3. Verify: cd sdk && prove -lj4 t
```

### Step P10.10: Client environment configuration (spec §31)

**NOTE**: §31 (CORRECTED) — call the env-config FFI
(temporal_core_client_env_config_load / _profile_load, header :918/:925), do
NOT reimplement envconfig.rs. Build the options struct, parse the returned
JSON into value classes. No TOML parser / per-OS path helper. No connect
signature change.

```text
1. RED: Write unit tests first (sdk/t/unit/envconfig.t), using override_env_vars:
   - options-struct built correctly from each kwarg combo; parse representative
     FFI JSON (multi-profile, TLS block, grpc_meta, codec) into value classes
     (T-envcfg-1..6); fail-string return → Argument (profile-not-found, strict
     unknown key, path+data conflict, both-disabled)
   - to_connect_config mapping (address→target, api_key-implies-tls,
     explicit-tls-overrides, grpc_meta→rpc_metadata), disabled tri-state,
     DataSource path-vs-data → TlsConfig (T-envcfg-7..9)
   - sdk/t/integration/envconfig.t: write temp toml → load_client_connect_config
     → connect → one RPC (T-envcfg-int-1)
2. GREEN: Temporalio/EnvConfig.pm + EnvConfig/{ClientConfigTLS,
   ClientConfigProfile,ClientConfig}.pm; Core/FFI env-config options-struct
   record + load/profile_load attaches; JSON parse → value classes;
   to_connect_config. Add a pin check that the two FFI symbols are present.
3. Verify: cd sdk && prove -lj4 t — **Phase 10 / v0.2 SDK feature contracts
   complete**
```

---

## Implementation Guidelines

- **TDD always**: RED before GREEN in every step; tests named by spec
  T-IDs in comments so coverage maps back to spec.md.
- **Spec is the contract**: spec.md §references in each step are
  authoritative (the old PLAN.md draft has been removed).
- **Test framework**: Test2::V1 with the explicit preamble
  (`use v5.38; use warnings; use utf8; use Test2::V1;`) — V1 does not
  auto-enable them (spec §12.1).
- **Classes**: `feature 'class'` + `no warnings 'experimental::class';`
  every class file; two-line ABOUTME header on every code file.
- **Dynamic scope across await**: `Syntax::Keyword::Dynamically`, never
  `local` (spec §16.1 — F::AA panic).
- **Canonical commands**: `cd sdk && prove -lj4 t` (unit/replay/integration),
  `prove -lj4 xt` (author), `cargo test` in ext/temporalio-perl-bridge,
  `dzil test` per distribution.
- **Integration tests** skip cleanly (skip_all) when the dev server binary
  or ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH is unavailable.
- **Header pin**: all FFI signatures target the header at the pinned
  sdk-rust tag; bumping the pin requires re-running P0.10's echo test.
- **Git**: never commit to main; feature branches; commit flow per
  .claude/rules/git-workflow.md (session-summary → commit-message →
  `git commit -S -F commit-msg.md`).

## Success Metrics

- Phase gates = spec §11 acceptance criteria, in order P0 → P5.
- Every spec test ID (T-*) implemented or explicitly marked
  deferred-with-reason in todo.md.
- Phase 3 gate: all-Perl hello-world completes against the ephemeral dev
  server. Phase 4 gate: greet-with-signal works end-to-end.
- v0.1.0: full matrix green in CI, POD coverage 100%, examples runnable.






