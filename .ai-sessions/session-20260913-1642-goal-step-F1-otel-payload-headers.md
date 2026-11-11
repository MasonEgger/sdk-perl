# Session Summary: OTel Outbound Trace Context as a Real Payload End to End (F1)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a three-iteration fix loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor dispatches), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F1, plan.md Section 6 Step F1 (Make OTel Outbound Headers Real Payloads End to End), GitHub #6 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (3), fix (2), finalize (1)
- **Steps completed**: 1 of 1 (F1, all 8 plan sub-steps)

## The Defect

The Fable review of d15a6db (the I6 workflow-outbound span step) found the OTel interceptor's trace context never survived a real outbound path, in two directions at once.

Outbound, `_carrier_to_payload` returned an unblessed `{ metadata, data }` hashref.
Every Runner root that emits headers encodes them through `Temporalio::Interceptor::Headers::to_payload_map`, whose `is_payload` test is `blessed($value) && $value->isa(temporal.api.common.v1.Payload)`.
An unblessed hashref fails that test, so the JSON converter encoded the whole hashref as a payload BODY and a receiver needed two decodes to reach the carrier.
That is exactly the double-encode class `lessons.md` recorded on 2026-06-26 for #10 GAP B, reintroduced by a new header producer.

Inbound, `_payload_to_carrier` required `ref $payload eq 'HASH'`, so a blessed wire Payload extracted nothing.
Payloads arriving at the inbound side come materialized from other messages (the activity Start task's `header_fields`, the `InitializeWorkflow` job's `headers`), and those are instances of the generated parent class, not of `Temporalio::Payload`.
With no carrier extracted there was no cached inbound context, so the outbound gate never opened either.

The I6 linkage test could not see either bug because it handed the outbound fixture's raw header value straight to the inbound hook, bypassing `to_payload_map` on the way out and the wire materialization on the way in.

## The Fix

- `_carrier_to_payload` now returns a blessed `Temporalio::Payload`, and its comment block records why the blessing is load-bearing, citing `is_payload` and sdk-python's `payload_converter.to_payloads([carrier])[0]` (`contrib/opentelemetry/_interceptor.py:675-682`). The `require Temporalio::Payload` is lazy so the module keeps its cheap load; pulling it in triggers the one-time vendored-proto parse.
- `_payload_to_carrier` duck-types on the `metadata`/`data` accessors when the value is blessed, and still accepts the unblessed hashref so hand-built fixtures and older header values keep decoding. Payload.pm's own POD states the duck-typing rule for consumers.
- A new `_carrier_from_context` holds the single rendering step (propagator lookup, `inject`, empty-carrier and die-to-undef degradation). Both header writers now sit behind it: the `_tracer-data` Payload writer `_inject_headers` (client outbound and workflow outbound alike) and the plain `Str => Str` Nexus writer `_WorkflowOutbound::_inject_str_headers`, which previously carried its own copy of the propagator dance. Only the WRITE differs now.
- POD gained the one-decode contract (a receiver recovers the carrier with a single decode, header type is `Mapping[str, Payload]` in both directions, inbound reads by duck-typing) and the outbound parent-missing gate (with `always_create_workflow_spans` off, a run that started with no `_tracer-data` header gets no span AND no injection; turning the option on gives both, with the new span parentless; `continue_as_new` injects nothing when the run context is absent). The replacement rule is documented too: each op injects its OWN span's context, an inbound `_tracer-data` already on the op is replaced rather than merged, and unrelated header keys are left alone.

## The Tests

All in `sdk/t/unit/tracing.t`:

- A replay-harness subtest driving the REAL Runner so the injected header goes through `to_payload_map` into the emitted `ScheduleActivity` command, then asserting the emitted value is a Payload, that its BODY is the carrier map rather than a serialized payload hashref, and that a SINGLE decode recovers the outbound span's traceparent. This is the reproduction route lessons.md prescribes for the double-encode class.
- Blessed wire Payload extraction on both inbound sides: the activity Start `header_fields` path and the `InitializeWorkflow.headers` path, each parenting on the carrier's traceparent, plus a direct `_payload_to_carrier` check.
- A `to_payload_map` pass-through regression: the injected payload comes back by reference address, unencoded, and decodes to the carrier.
- Per-op own-span equality across the traced outbound ops (local activity, child start, child signal, external signal): each injected traceparent equals that op's own span, not the run's.
- Header replacement: `signal_external_workflow` asserts the injected carrier is the NEW span's traceparent rather than the stale sender one, and that an unrelated `x-other` key survives.
- The outbound parent-missing gate: no span and no header with the option off (including `continue_as_new`), one parentless span plus an injected header with it on.

## The Fix Loop

Three validator iterations, warn at 1 and 2, clean at 3, all on test STRENGTH rather than on production code.
The production hunks in `TracingInterceptor.pm` were unchanged from iteration 1 through 3.

- Iteration 1 warn: assertions that a mutation could not distinguish. Rewritten to compare against the specific span's traceparent instead of counting keys or checking definedness.
- Iteration 2 warn: the recorded mutation transcript needed to be verbatim and to name which assertions are boolean `ok()` calls (they print no comparison table), and to note that `FakeOTel`'s traceparent counter is monotonic across the file, so the transcript's digits shift if a subtest ahead of it creates more spans.
- Iteration 3: clean, with one info-level wording fix applied at finalize (the FAILS-on-HEAD paragraph claimed the header assertion also fails; the subtest actually returns before reaching it, because with no span there is no injection to check).

## Key Actions

- Verified the sdk-python `_context_carrier_to_headers` / `_context_from_headers` contract against `../sdk-python/temporalio/contrib/opentelemetry/_interceptor.py` and cited the line ranges in code comments.
- Ran the full unit/replay/integration suite (911 tests / 211 files) and the author suite (474 tests / 8 files) at finalize; both green.
- Scanned the added lines for dashes and banned vocabulary before committing; clean.
- No deviations recorded; `.ai-sessions/implementation-notes.md` did not exist at finalize time.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Mode: finalize dispatch for F1 | Applied the iter-3 info wording fix, ran the dash and banned-word scans, ran both suites, wrote this summary, extended lessons.md, generated the commit message, committed, pushed | Converged, one signed commit pushed to issue-closeout |

## Efficiency Insights

**What went well:**
- The 2026-06-26 lessons entry named both the failure class and its reproduction route (drive the real Runner through the replay harness, decode the emitted `ScheduleActivity.headers` once), so the RED test was designed from the lesson rather than rediscovered.
- Collapsing the two propagator call sites into `_carrier_from_context` made the Nexus string-header writer and the Payload writer share a rendering step, which is what made the parent-missing gate uniform across both.

**What could improve:**
- Two of the three validator iterations were spent on assertion strength. Writing the mutation transcript FIRST, then the assertions that the mutation must break, would have collapsed them into one pass.

**Course corrections:**
- Iteration 1 replaced a key-count assertion on the replacement test; a Perl hash cannot hold two values under one key, so counting keys after a replace is tautological and proves nothing.

## Process Improvements

- When a test records a mutation transcript, paste it verbatim from `prove -lv` and annotate which numbered assertions are bare `ok()` calls, since those print no diagnostic table and a reader otherwise expects one.
- A fixture with a monotonic counter (here `FakeOTel`'s traceparent sequence) makes any recorded transcript position-dependent; say so next to the transcript rather than leaving a future reader to discover it when a subtest is inserted above.

## Observations

- The I6 linkage test is the cautionary shape: a test that wires the outbound side's output directly into the inbound side's input exercises neither the encoder nor the wire materialization, so it stays green across both halves of a round-trip bug.
- `Temporalio::Payload` and the generated parent class are the same class under two names for the outbound producer, but not for the inbound consumer, which sees whatever the containing message materialized. Producers bless with the stable name; consumers duck-type.

## Suggested Skills for Next Session

- None specific; the next step should consult todo.md and spec.md directly for its own scope.
