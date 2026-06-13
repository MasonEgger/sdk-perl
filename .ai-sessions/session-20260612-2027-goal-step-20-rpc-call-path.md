# Session Summary: Goal Step 20 — RPC call path + §7.5 error mapping (P1.8)

**Date**: 2026-06-12
**Duration**: ~35 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (<$1 — header/reference-SDK reads, one gcc probe, several prove runs, no cargo)
**Model**: claude-fable-5

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P1.8.1 RED through P1.8.5 Verify in one
  commit; the SDK can now make raw RPCs against a live server:
  `Client->_rpc_call` (async funnel for every future client method) +
  the spec §7.5 MUST-match gRPC status → exception mapping in
  `Temporalio::Core::Callback::rpc_error_for`
- **Subagent dispatches**: this summary covers dispatch 20
- **Steps completed**: 5 of 5 P1.8 sub-items (P1.8.1–P1.8.5)

## Key Actions

- MUST-match constants verified against reference SDK source per the
  CLAUDE.md non-negotiable:
  - gRPC status code → name table — sdk-python `service.py:418-437`
    (`RPCStatusCode` IntEnum: 0 OK, 1 CANCELLED, 2 UNKNOWN,
    3 INVALID_ARGUMENT, 4 DEADLINE_EXCEEDED, 5 NOT_FOUND,
    6 ALREADY_EXISTS, 7 PERMISSION_DENIED, 8 RESOURCE_EXHAUSTED,
    9 FAILED_PRECONDITION, 10 ABORTED, 11 OUT_OF_RANGE,
    12 UNIMPLEMENTED, 13 INTERNAL, 14 UNAVAILABLE, 15 DATA_LOSS,
    16 UNAUTHENTICATED). Spec §7.5's `status_name => 'unavailable'`
    fixes the lowercase convention; names are the lowercased canonical
    gRPC names.
  - ALREADY_EXISTS special case — sdk-python `client/_impl.py:184-192`
    and sdk-ruby `internal/client/implementation.rb:84-97`: only when
    `grpc_status.details[0]` unpacks as
    `temporal.api.errordetails.v1.WorkflowExecutionAlreadyStartedFailure`
    does it become WorkflowAlreadyStarted (run_id from the unpacked
    failure); otherwise the plain RPC error is re-raised. Mirrored
    exactly (fallback to RpcError `already_exists`).
  - Spec §6.2/§7.5 class-name note: the table's "NotFound::Workflow"
    phrasing means the §6.2 classes `WorkflowNotFound` /
    `ActivityNotFound` / `NamespaceNotFound` (all `:isa` NotFound).
- C ground truth read, never from memory: header lines 8-14
  (RpcService: Workflow=1..Health=5), 241-253 (RpcCallOptions), 261-266
  (rpc callback typedef), 902-911 (`client_rpc_call`); client.rs
  430-560 (`temporal_core_client_rpc_call`: tonic::Status →
  (code, message, details) where details is the raw
  grpc-status-details-bin = serialized google.rpc.Status and may be a
  NON-NULL EMPTY byte array; non-Status errors → code 0 + message —
  "Status code may still be 0 with a failure message"). gcc offsetof
  probe for RpcCallOptions: service 0, rpc 8, req 24, retry 40,
  metadata 48, binary_metadata 64, timeout_millis 80,
  cancellation_token 88, sizeof 96 — Platypus record sizeof matches.
- Proto plumbing: `google.rpc.Status` and the errordetails messages are
  reachable ONLY through `google.protobuf.Any` (no service proto imports
  them), so they were missing from the generated classes. Vendored
  `sdk/share/proto/google/rpc/status.proto` from sdk-rust's STANDALONE
  `crates/protos/protos/google/rpc/` root (outside api_upstream;
  `vendor-protos.pl` grew a tree entry for it) and added it plus
  `temporal/api/errordetails/v1/message.proto` as explicit roots in
  `Temporalio::Core::Proto::_root_files`.
- RED (P1.8.1): `sdk/t/unit/rpc_mapping.t` — table-driven over every
  §7.5 row (19 code/rpc/class rows), isa chains (T-exc-4 style),
  catch-all (code 99, code 0+message), google.rpc.Status details decode
  (present/empty/absent/garbage), and the ALREADY_EXISTS unpack on
  Start/SignalWithStart (plus wrong-Any-type and no-details fallbacks).
  Observed RED (google.rpc.Status unresolvable, rpc_error_for missing).
- GREEN (P1.8.2): `rpc_error_for` in Callback.pm — %GRPC_STATUS_NAME +
  %CLASS_FOR_CODE tables, `_decode_grpc_status` (empty == absent; never
  dies on garbage), `_unpack_any` (type_url suffix match), NOT_FOUND
  routed on the rpc name (/Namespace/ → NamespaceNotFound, /Activity/ →
  ActivityNotFound, else WorkflowNotFound), FAILED_PRECONDITION +
  QueryWorkflow → QueryRejected, RpcError carries
  status_code/status_name/details (decoded Status object).
- RED (P1.8.3): `sdk/t/integration/client_rpc.t` (DevServer-backed,
  same CLI skip_all gate) — DescribeNamespace proto round-trip,
  nonexistent namespace → NamespaceNotFound, and a
  `local *Temporalio::Core::FFI::client_rpc_call` spy asserting the
  RpcCallOptions record (retry set, service 1, rpc/req bytes, no
  timeout/token). Observed RED live (3 subtests, _rpc_call missing).
- GREEN (P1.8.4): `RpcCallOptions` record + `client_rpc_call` attach in
  Core::FFI; `async method _rpc_call` in Client.pm (probe confirmed
  `async method` parses under feature-class + Future::AsyncAwait 0.71):
  retry defaults ON (spec §7.5 — core applies RetryConfig), response
  class derived `s/Request\z/Response/`, options + @keep held as
  lexicals across the await, failure ⇔ defined failure_message,
  `error_context` passthrough for the P1.10 ALREADY_EXISTS context.
- Verify (P1.8.5): targeted pair 2 files / 8 subtests PASS (integration
  ran live, not skipped); full suite `prove -lj4 t` → 19 files, 100
  tests, exit 0. todo.md P1.8.1–5 checked; plan.md Current Status
  updated (next: P1.9).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P1.8 rpc call path), verify §7.5 against sdk-python/sdk-ruby, read actual headers | Ground-truth reads (header, client.rs, service.py, _impl.py, implementation.rb), gcc offsetof probe, RED rpc_mapping.t, GREEN rpc_error_for + status.proto vendoring, RED client_rpc.t, GREEN RpcCallOptions/_rpc_call, verify, plan/todo updates, summary, commit, push | Suite 19 files / 100 tests, exit 0 |

## Efficiency Insights

**What went well:**
- Reading client.rs's error arm up front surfaced two semantics the
  header omits: details arrive as a NON-NULL EMPTY ByteArray when tonic
  has no grpc-status-details-bin, and non-Status errors come back as
  code 0 with a message — both became explicit test rows instead of
  field bugs.
- The pre-flight `Temporalio::Core::Proto::resolve` probe (one-liner)
  caught the missing google.rpc.Status/errordetails classes BEFORE the
  test was written, so the vendoring landed as designed work, not as a
  mid-GREEN scramble.

**What could improve:**
- One avoidable debug cycle: `T2->is($options->cancellation_token, undef, ...)`
  hit the known record-accessor-on-NULL list-context collapse — that
  exact trap is already in lessons.md (2026-06-11); re-skimming the
  Testing lessons before writing assertion-heavy tests would have
  avoided it.

**Course corrections:**
- None of substance. The existing kind-4 Callback builder (P1.2) already
  resolved rpc completions with the raw fields hashref; the plan's
  "mapping in the rpc branch" landed as `rpc_error_for` beside it (the
  table lives in Callback.pm per spec §7.5; _rpc_call applies it —
  required because the special cases need the rpc-name context only the
  caller has).

## Process Improvements

- For protos delivered inside `google.protobuf.Any`, check
  `resolve()` reachability before writing tests — Any-only messages are
  invisible to import-driven schema loading and need explicit roots.

## Observations

- sdk-rust keeps `google/rpc/status.proto` in a standalone proto root
  (`crates/protos/protos/google/`), not under api_upstream — a re-pin
  re-vendor now picks it up via the new vendor-protos.pl tree entry.
- `async method` (Future::AsyncAwait 0.71 + perl 5.38.2 feature
  'class') parses and runs fine for a SECOND method in a file whose
  class is already declared — the one-`:isa`-per-file lesson constrains
  class declarations, not async methods.
- The dev server resolves DescribeNamespace on a nonexistent namespace
  as NOT_FOUND immediately even with retry set — NOT_FOUND is not in
  core's retryable set, so the mapping path is exercised without
  burning the retry budget.

## Suggested Skills for Next Session

- No matching skill for the next step (P1.9 common types —
  RetryPolicy/Priority/TypedSearchAttributes is pure-Perl proto work;
  no Perl skill exists in the registry).
