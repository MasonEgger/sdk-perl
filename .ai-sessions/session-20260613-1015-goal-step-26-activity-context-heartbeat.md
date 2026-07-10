# Session Summary: Goal Step 26 — Activity::Context + heartbeat (P2.3)

**Date**: 2026-06-13
**Duration**: ~25 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (<$1 — reference-SDK reads, one RED/GREEN cycle, one
  dep install, two test runs)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P2.3.1 RED through P2.3.3 Verify in one
  commit. The per-invocation activity context now exists: `info()`,
  `heartbeat(@details)`, `cancellation`, and the dynamically-scoped
  `context()` lookup. Full activity dispatch/execution remains P2.4.
- **Subagent dispatches**: this summary covers dispatch 26
- **Steps completed**: 3 of 3 P2.3 sub-items (P2.3.1–P2.3.3)

## Key Actions

- MUST-match semantics verified against reference SDK source and quoted:
  - ActivityInfo field set from sdk-python `temporalio/activity.py:92-139`
    (`Info`: activity_id, activity_type, attempt,
    current_attempt_scheduled_time, heartbeat_details, heartbeat_timeout,
    is_local, namespace, schedule_to_close_timeout, scheduled_time,
    start_to_close_timeout, started_time, task_queue, task_token,
    workflow_id, workflow_run_id, workflow_type) and cross-checked against
    sdk-ruby `activity/info.rb:8-27` (same field set, `Data.define`).
  - `context()` lookup mirrors sdk-python `_current_context` contextvar
    (`activity.py:161,303-329` — `info()`/`heartbeat()` are module functions
    that read the current context and raise `RuntimeError` when absent) and
    sdk-ruby `Activity::Context.current`.
  - Heartbeat is SYNCHRONOUS in the reference SDKs: sdk-ruby
    `internal/worker/activity_worker.rb:445-454`
    (`OutboundImplementation#heartbeat`) builds
    `CoreInterface::ActivityHeartbeat.new(task_token:, details:
    convert_to_payload_array(data_converter, details))` and calls
    `bridge_worker.record_activity_heartbeat(...).to_proto` — payload
    conversion only, no codec await; core throttles. Our Perl
    `heartbeat()` follows this: synchronous payload conversion via the data
    converter's payload converter, no async codec chain (codecs are
    Future-returning here and would break the sync call — deferred).
- FFI signature transcribed from the pinned C header (CLAUDE.md
  non-negotiable): `temporal-sdk-core-c-bridge.h:1061`
  `const TemporalCoreByteArray *temporal_core_worker_record_activity_heartbeat(TemporalCoreWorker *, TemporalCoreByteArrayRef heartbeat)`
  — SYNCHRONOUS (not a callback bridge call), returns NULL on success or an
  owned byte array describing the error ("Returns error if any. Must be freed
  if returned."). Attached in `Core::FFI` as
  `worker_record_activity_heartbeat`.
- Heartbeat proto wraps `coresdk.ActivityHeartbeat { bytes task_token = 1;
  repeated temporal.api.common.v1.Payload details = 2; }`
  (`share/proto/temporal/sdk/core/core_interface.proto:22-24`), resolved via
  `Temporalio::Core::Proto::resolve('coresdk.ActivityHeartbeat')`.
- Context scoping idiom (spec §9.3 / §16.1): `our $CURRENT` in
  `Temporalio::Activity::Context`, set by the dispatcher with
  `dynamically $...::CURRENT = $ctx;` — NEVER `local`. The RED test proves
  `context()` resolves correctly BOTH before and after an `await` (the
  exact F::AA savestack panic case), and raises once the scope exits.
- RED (P2.3.1): `sdk/t/unit/activity_context.t` — context()-outside-raises,
  context()-across-await regression, info() fields, cancellation is a
  Temporalio::Cancellation (cancel propagates), heartbeat encodes the proto
  with task_token + N detail payloads (round-trips through the converter),
  empty-heartbeat, and Heartbeat-on-non-null-recorder-return (T-act-7).
- GREEN (P2.3.2): `Temporalio::Activity::Context` (info/heartbeat/cancellation/
  client/data_converter/payload_converter + `$CURRENT`), the
  `context()`/`info()`/`heartbeat()` package functions on
  `Temporalio::Activity`, and the heartbeat FFI attach.
- Verify (P2.3.3): unit green (7 subtests), full `prove -lj4 t` → 27 files,
  164 tests, exit 0 (was 26/157).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute P2.3 (Activity::Context + heartbeat), dynamically scoping across await, header-true heartbeat FFI, MUST-match info/heartbeat vs sdk-python/ruby | Reference reads (python Info/_Context/heartbeat, ruby Info/Context/OutboundImpl), header read (record_activity_heartbeat), proto read (ActivityHeartbeat), installed Syntax::Keyword::Dynamically, RED unit, GREEN Context.pm + Activity.pm functions + FFI attach, full suite, todo update, summary, commit, push | Suite 27 files / 164 tests exit 0; T-act-7 green |

## Efficiency Insights

**What went well:**
- The existing async `Temporalio::Converter::Data` + `Temporalio::Cancellation`
  + `Core::Proto::resolve` meant the Context body was thin: convert, wrap,
  serialize, hand to a recorder coderef.
- Decoupling the FFI behind a `heartbeat_recorder` coderef made the Context
  unit-testable without a live worker AND leaves the sync-activity fork pool
  (P2.5) a clean seam to substitute a pipe relay.

**What could improve:**
- `Syntax::Keyword::Dynamically` was declared in `sdk/cpanfile` but NOT
  installed in `~/perl5` — the RED test failed to even compile. Had to
  `cpanm --local-lib=~/perl5 --notest Syntax::Keyword::Dynamically` (0.14)
  first. It is a hard dependency per spec §9.3, so this was the right fix,
  not a workaround.

**Course corrections:**
- Initial test draft round-tripped a heartbeat detail through
  `from_payload` in list context with an awkward guard; simplified to a
  scalar assignment since `Converter::Payload->from_payload` returns a
  single value.

## Process Improvements

- Heartbeat is a SYNC FFI call, but this SDK's payload codec chain is async
  (`Future`-returning). v0.1 `heartbeat()` applies only the synchronous
  payload converter (exactly what sdk-ruby does); a codec chain over
  heartbeat details is deferred until a sync-friendly codec path exists.
  Documented inline in `Context.pm` so P2.4/P2.5 don't reintroduce an await.

## Observations

- The Context holds the heartbeat behind a coderef rather than a
  worker_ptr/runtime pair. P2.4's activity dispatcher will supply the real
  recorder: wrap the FFI return with `Temporalio::Core::ByteArray->wrap`,
  read `->bytes`, `->free`, return that string (or undef on NULL). This is
  the same wrap/read/free pattern `Worker::_ensure_worker` uses for the
  worker-creation fail byte array.
- `info` is an unblessed hashref in v0.1 (the dispatcher freezes it from the
  ActivityTask start job). The reference SDKs use a frozen data class; a Perl
  Info value class can come later if accessor ergonomics warrant it.

## Suggested Skills for Next Session

- No matching skill for P2.4 (activity poll loop): injectable poll source,
  `worker_poll_activity_task`/`worker_complete_activity_task` FFI attaches,
  `ActivityDispatcher.pm` + `PollLoop.pm`, the dynamically-scoped Context
  wiring, and the running-activities task_token map. Reference ground truth:
  spec §8.4, sdk-ruby `internal/worker/activity_worker.rb`
  (poll/execute/complete + the OutboundImplementation heartbeat recorder we
  mirror), and the P1.2 `Core::Callback` poll-kind path. The
  `temporal:temporal-developer` skill is end-user usage, not SDK internals.
