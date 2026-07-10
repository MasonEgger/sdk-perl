# Session Summary: Goal Step 33 — workflow timers start_timer/sleep + FireTimer + CancelTimer (P3.5)

**Date**: 2026-06-13
**Duration**: ~30 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (<$2 — spec/proto/reference reads, one
RED/GREEN cycle with one cancellation-mechanics debugging iteration, full suite)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.5.1 RED through P3.5.3 Verify in one commit.
  The workflow body can now SET TIMERS: `start_timer` / `sleep` emit a
  `StartTimer` command with a deterministic timer-scoped seq, park the body on
  a `Temporalio::Workflow::Future`, and the runner resolves that Future when the
  matching `FireTimer` job arrives. Cancelling a timer Future emits `CancelTimer`
  and surfaces a `Temporalio::Exception::Cancelled` at the await site.
- **Subagent dispatches**: this summary covers dispatch 33
- **Steps completed**: 3 of 3 P3.5 sub-items (P3.5.1–P3.5.3)

## Key Actions

- Confirmed scope against plan P3.5 + spec section 10.2 (`start_timer`/`sleep`
  signatures, line 1847–1848) + 10.3 step 4 (`FireTimer { seq }` resolves
  `pending_timers{seq}` with undef, spec line 1923) + 10.7 T-wf-6 (spec line
  2077). The timer pattern directly mirrors the P3.4 activity pattern (emit a
  command with a deterministic seq, park on a `Workflow::Future`, resolve on the
  correlated job).
- **MUST-match semantics, cross-checked against reference SDKs:**
  - **Separate seq spaces.** sdk-python `_workflow_instance.py` uses
    `_next_seq("timer")` (line 2724) vs `_next_seq("activity")` (line 3058) —
    a per-type counter dict (`_next_seq`, lines 2384–2387). sdk-ruby
    `outbound_implementation.rb` uses `@timer_counter` (line 303) vs
    `@activity_counter` (line 68). So a workflow's first timer and first
    activity are BOTH seq 1, in independent spaces. This step split the runner's
    single `$seq_counter` into `$activity_seq_counter` + `$timer_seq_counter`.
  - **StartTimer shape.** Vendored proto
    `sdk/share/proto/.../workflow_commands/workflow_commands.proto` lines 54–58:
    `StartTimer { uint32 seq = 1; google.protobuf.Duration start_to_fire_timeout
    = 2; }`. sdk-python `_TimerHandle._apply_start_command` (line 3024–3032):
    `command.start_timer.seq = self._seq` and
    `start_to_fire_timeout.FromNanoseconds(int(delay * 1e9))`. The duration is
    encoded via the existing `_duration` helper (secs+nanos, P0.11 ground truth).
  - **FireTimer correlation.** Proto `workflow_activation.proto` lines 217–220:
    `FireTimer { uint32 seq = 1; }`. sdk-python `_apply_fire_timer` (lines
    726–733): `handle = self._pending_timers.pop(job.seq, None); if handle:
    self._ready.append(handle)` — an ABSENT handle is IGNORED, not an error
    (the timer may have been cancelled-and-removed earlier in the same
    activation). The runner's `_apply_fire_timer` mirrors this (`return unless
    defined $future`).
  - **CancelTimer.** Proto lines 60–63: `CancelTimer { uint32 seq = 1; }`.
    sdk-python `_TimerHandle._apply_cancel_command` (line 3034–3038):
    `command.cancel_timer.seq = self._seq`. sdk-ruby (lines 315–330): the
    cancel callback `pending_timers.delete(seq)`, and IF still present, adds the
    `CancelTimer` command and `fiber.raise(CanceledError)`. The pending-state
    guard (only emit on the FIRST cancel of a still-pending timer) is honored.
- RED (P3.5.1): `sdk/t/replay/timers.t` — 5 subtests / 17 assertions:
  - T-wf-6: `sleep(60)` on the InitializeWorkflow activation emits exactly one
    `StartTimer` (seq 1, 60s, 0 nanos); body parked, no completion yet.
  - `FireTimer{seq:1}` on the next activation resumes the body -> one
    `CompleteWorkflowExecution` carrying the post-sleep return.
  - `start_timer(30)` WITHOUT await: `StartTimer` + `CompleteWorkflowExecution`
    in the same activation (body did not block).
  - Separate seq space: a fresh runner's first timer is seq 1 (not bumped by an
    activity counter).
  - CancelTimer: a body that starts a timer, cancels its Future, and awaits ->
    `StartTimer` + `CancelTimer` (same seq) + completion; the await site raised
    `Temporalio::Exception::Cancelled` (asserted via the workflow returning the
    string `'cancelled'`).
  - Three fixtures (one `:isa` class per file under Future::AsyncAwait —
    lessons.md): `t/lib/WfDef/TimerSleeper.pm`, `TimerStarter.pm`,
    `TimerCanceller.pm`.
- GREEN (P3.5.2):
  - `lib/Temporalio/Workflow/Commands.pm` — `start_timer($fields)` and
    `cancel_timer($seq)` builders.
  - `lib/Temporalio/Workflow/Runner.pm` — split the seq counter into
    `$activity_seq_counter` + `$timer_seq_counter`; added `%pending_timers`;
    `start_timer($seconds)` method (timer-seq alloc, StartTimer command +
    Duration, registers a timer Future); `_apply_fire_timer($job)` handler
    (resolve `pending_timers{seq}` via `->done`, ignore absent); wired
    `fire_timer` into `_apply_job`; new sub-package
    `Temporalio::Workflow::Runner::_TimerFuture` (see below).
  - `lib/Temporalio/Workflow.pm` — `start_timer($seconds)` and `sleep($seconds)`
    delegate to the runner.
- REFACTOR (P3.5.3 fold-in): POD updates across Commands.pm (FUNCTIONS),
  Runner.pm (Scope + Sequence-numbers sections now describe the timer surface
  and the separate seq spaces), and Workflow.pm (functional-surface comment).
- Verify: targeted file green (5 subtests / 17 assertions), then full suite
  `prove -lj4 t` -> 34 files, 205 tests, exit 0 (integration ran LIVE against
  the dev server, not skipped).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.5 timers — start_timer/sleep -> StartTimer + FireTimer -> resolve pending-timer Future; CancelTimer on cancel; MUST-match StartTimer/FireTimer/CancelTimer + Duration vs sdk-python/sdk-ruby; deterministic seq discipline) | Read latest summary + plan P3.5 + spec 10.2/10.3/10.7; cross-checked sdk-python `_workflow_instance.py` (`_next_seq`, `_timer_impl`, `_apply_fire_timer`, `_TimerHandle`) + sdk-ruby `outbound_implementation.rb` timer block + vendored coresdk protos; built RED replay test (5 subtests) + 3 fixtures; added `start_timer`/`cancel_timer` builders + runner `start_timer`/`_apply_fire_timer` + `_TimerFuture` cancel override + Workflow `start_timer`/`sleep`; fixed the native-cancel-vs-Cancelled-failure mechanics; full-suite verify; todo update; summary; commit; push | Suite 34 files / 205 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The activity pattern from P3.4 was a precise template. The schedule->resolve
  machinery (command builder, pending-Futures map keyed by seq, job handler that
  resolves the Future) ported almost verbatim to timers; the only new design
  work was the seq-space split and the cancellation semantics.
- Reading BOTH reference SDKs settled the seq-space question definitively:
  sdk-python's `_next_seq(type)` dict and sdk-ruby's distinct `@timer_counter`
  both prove timers and activities have INDEPENDENT seq spaces starting at 1.
  Asserted this explicitly in a dedicated subtest.

**What could improve:**
- Burned one iteration on CPAN Future cancellation mechanics. The first draft
  used `$future->on_cancel(sub { ...; $future->fail(Cancelled) })`. But CPAN
  Future's `->cancel` transitions the future to the NATIVE cancelled state and
  fires `on_cancel` callbacks AFTER it is already ready, so the in-callback
  `->fail` is a silent no-op and `await` throws a bare `"... was cancelled"`
  string — losing the `Temporalio::Exception::Cancelled` identity the body
  expects. Probed this directly with a one-liner, then switched to a
  `_TimerFuture` subclass that OVERRIDES `cancel` to call the command-emitting
  callback and then `->fail(Cancelled)` (never entering the native cancelled
  state). This matches the references, which raise a cancellation EXCEPTION into
  the awaiting frame (sdk-ruby `fiber.raise`, sdk-python task-cancel ->
  `CancelledError`), not a transport-level cancel.

## Process Improvements

- For any Temporal "cancellable awaitable" backed by a CPAN Future, do NOT model
  cancellation as Future's native `->cancel` (which yields a bare-string
  rejection at `await`). Model it as a `->fail` with the proper
  `Temporalio::Exception::*`, via a Future subclass that overrides `cancel`. The
  reference SDKs all raise a cancellation EXCEPTION into the awaiting frame; the
  exception identity is load-bearing (the body catches `Cancelled` specifically).
  This will recur for activity cancellation (P3.7), `wait_condition` timeout,
  and child-workflow cancel — reuse the `_TimerFuture` override shape.

## Observations

- `sleep` and `start_timer` are currently identical at the Perl layer (both
  return the timer Future without awaiting); the body `await`s the result. The
  spec documents `sleep` as the await alias, but returning the awaitable (rather
  than awaiting inside the sub) keeps the await in the CALLER's async frame so
  the dynamically-scoped `$CURRENT` runner pointer survives the suspension
  (spec section 16.1). The fixture awaits `sleep(...)`, so behavior matches.
- The `summary` kwarg on `start_timer`/`sleep` (spec line 1847, user_metadata in
  both references) is not yet threaded through — it is optional and default-safe
  (unset). It joins when the workflow-author metadata surface lands.
- `_apply_fire_timer` ignoring an absent handle is the documented stale-fire
  guard: a timer cancelled-and-removed earlier in the same activation must not
  error when its FireTimer arrives (sdk-python comment, lines 729–730).

## Suggested Skills for Next Session

- No matching skill for the next step (P3.6: workflow poll loop + dispatcher
  cache + eviction — `worker_poll_workflow_activation` /
  `worker_complete_workflow_activation` FFI, `WorkflowDispatcher.pm`, RemoveFromCache
  teardown). Ground truth: spec section 8.3 (poll loop steps 1–10, eviction fast
  path, codec boundary) + 10.3 RemoveFromCache, and the sibling worker loops in
  sdk-ruby `lib/temporalio/worker/` + sdk-python `worker/_workflow.py`. The
  `temporal:temporal-developer` skill is end-user usage guidance, not SDK
  internals.
