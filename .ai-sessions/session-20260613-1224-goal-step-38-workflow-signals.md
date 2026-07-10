# Session Summary: Goal Step 38 — workflow signal dispatch, buffering, and async-handler tracking (P4.1)

**Date**: 2026-06-13
**Duration**: ~40 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: moderate (<$3 — survey of Runner + Definition + sdk-python signal-instance internals, one RED test with three fixtures, one GREEN implementation pass, full live suite)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P4.1.1 RED through P4.1.3 Verify in one commit. Signals now DISPATCH in the deterministic runner; the :Signal attribute registration from P3.1 is wired to actual handler invocation, buffering, and async-handler tracking.
- **Subagent dispatches**: this summary covers dispatch 38
- **Steps completed**: 3 of 3 P4.1 sub-items (P4.1.1–P4.1.3)

## Key Actions

- Confirmed scope against plan P4.1 + spec section 10.3 (SignalWorkflow) and
  verified semantics against sdk-python `worker/_workflow_instance.py`:
  `_apply_signal_workflow` (named -> dynamic -> buffer), `_process_signal_job`
  (in-progress tracking via `_in_progress_signals`), `activate()`'s four ordered
  job sets (patches, signals+updates, non-queries incl. initialize, queries —
  applied with a pump between sets), and `workflow_all_handlers_finished`.
- **RED (P4.1.1):** wrote `sdk/t/replay/signals.t` with five subtests and three
  fixtures (`WfDef::SignalGreeter`, `WfDef::AsyncSignalHandler`,
  `WfDef::DynamicSignalGreeter`): (1) T-wf-3 signal in the init activation is
  visible to the :Run continuation when its timer fires; (2) signals delivered
  in arrival order; (3) unmatched signal routes to the dynamic catch-all
  handler with (name, @args); (4) a signal with no handler is buffered (not an
  error) and remains queued; (5) an async :Signal handler that awaits its own
  timer is tracked in the in-progress set, parks (emitting its StartTimer)
  without completing the workflow, and is pumped to completion on a later
  FireTimer. Confirmed 5/5 RED.
- **GREEN (P4.1.2):** in `Temporalio::Workflow::Runner`:
  - Added `_ordered_job_sets` and rewired `process_activation` to apply the four
    de-facto job sets with a `_pump` between each (spec section 10.3 step 3).
    Signals (set 1) run BEFORE InitializeWorkflow (set 2).
  - Added `%buffered_signals` (name -> [jobs]) and `%in_progress_handlers`
    (id -> Future) with `$handler_seq`.
  - `_apply_signal_workflow`: buffers when no instance yet OR no matching
    handler; else dispatches. `_resolve_signal_handler`: named then dynamic
    (sdk-python `_signals.get(name) or _signals.get(None)`).
  - `_dispatch_signal`: runs the handler (sync or async) through
    `Future->call(sub { Future->wrap(...) })` (the lessons.md idiom), calling a
    dynamic handler as `$instance->$h($name, @args)` and a named one as
    `$instance->$h(@args)`. A pending handler Future is tracked in
    `%in_progress_handlers` and removed via `on_ready`.
  - `_drain_buffered_signals`: called at the end of `_apply_initialize` once the
    instance exists; dispatches buffered signals whose name now resolves, in
    arrival order.
  - `_all_handlers_finished` + a gate in `_build_completion`: even when :Run has
    returned, CompleteWorkflowExecution is withheld while a handler Future is
    in-flight.
  - `evict` now also cancels in-progress handler Futures.
  - Test helper `_buffered_signal_names`.
- **Verify (P4.1.3):** `prove -lj4 t` -> 39 files / 235 tests, exit 0
  (integration ran LIVE against the dev server). signals.t: 5 subtests, all
  green.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P4.1 — SignalWorkflow dispatch + queueing + async handler tracking) | Verified semantics against spec section 10.3 + sdk-python; wrote signals.t + 3 fixtures (RED 5/5); implemented job ordering, signal dispatch/buffer/drain, in-progress-handler tracking, completion gating, evict cancel (GREEN); full live-suite verify; todo update; summary; commit; push | Suite 39 files / 235 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The async-handler subtest used the workflow body's own `until($done)` poll-park
  (wait_condition is P4.3, not yet available) to gate completion on the handler's
  effect, which exercised both the in-progress tracking AND the re-pump-per-timer
  loop without needing a new primitive.
- Reading sdk-python's `activate()` job-set split first meant the Perl
  job-ordering and the buffer-before-init flow fell straight out — the "signals
  in set 1 run before initialize in set 2, so buffer then drain" insight is the
  whole reason T-wf-3 works.

**What could improve:**
- The completion gate on `_all_handlers_finished` is belt-and-suspenders for a
  well-behaved workflow (whose body awaits the handler's effect). It earns its
  keep only for a misbehaving body that returns while a handler is still live;
  worth a dedicated test in a later hardening pass if that path matters.

**Course corrections:**
- None — RED was clean and GREEN passed on the first full run.

## Process Improvements

- For a runner job-kind that needs an instance (signals, queries, updates), check
  the job-ordering relative to InitializeWorkflow FIRST: signals are ordered
  before initialize, so the buffer-then-drain-after-init flow is mandatory, not
  optional.

## Observations

- A `:Signal` handler is a METHOD, so it cannot run until `_apply_initialize`
  has created the instance — even though the handler *definition* exists at
  class-compile time. This is the structural reason signals delivered in the
  init activation must be buffered then drained, distinct from sdk-python where
  `self._signals` is populated in `__init__` before the primary task starts.
- Dynamic signal calling convention chosen as `$instance->$h($name, @args)` to
  mirror sdk-python's dynamic `(name, args)`; named handlers get the bare
  decoded args.
- The pre-existing `Test::Builder loaded after Test2` warning from
  determinism.t is unrelated to this change and remains cosmetic.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — usage-level confirmation of query semantics
  for P4.2 (QueryWorkflow: synchronous handler, queries ordered LAST in the
  activation, a dying query handler produces a query FAILURE response not a
  workflow/task failure, RespondToQuery command). Ground truth remains spec
  section 10.3 + sdk-python `_apply_query_workflow` / `_apply_query_job`.
