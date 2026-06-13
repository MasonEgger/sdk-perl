# Session Summary: Goal Step 28 — Sync activity fork pool (P2.5)

**Date**: 2026-06-13
**Duration**: ~50 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: moderate (<$3 — reference-SDK + spec reads, one
  RED/GREEN/REFACTOR cycle, three fork-behavior debug spikes, multiple
  focused + full suite runs)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P2.5.1 RED through P2.5.4 Verify in one commit.
  Sync activities now run in an `IO::Async::Function` fork pool: forked
  children close inherited parent FDs (the runtime wakeup fd), heartbeats from
  a child relay back to the parent's FFI call, cooperative cancellation
  propagates parent->child, and the dispatcher routes sync-declared activities
  to the pool / async ones to the main loop. **Phase 2 acceptance green at unit
  level.**
- **Subagent dispatches**: this summary covers dispatch 28
- **Steps completed**: 4 of 4 P2.5 sub-items (P2.5.1–P2.5.4)

## Key Actions

- Sync/async flag plumbing: added a `sync` field to
  `Temporalio::Activity::FunctionDefinition` (with a `sync` reader), a
  `:Defn(sync=1)` option parsed in `Temporalio::Activity::Attributes`, and
  carried it into the registry entry from both the FunctionDefinition and the
  class `:Defn` paths (`Temporalio::Activity::Definition`). Routing keys off
  `$def->{sync}` (spec section 8.4 step 6: `async sub`/`async method run :Defn`
  -> main loop; plain sub/method -> fork pool).
- New modules:
  - `Temporalio::Activity::Invocation` — the serializable cross-fork
    invocation struct (REFACTOR P2.5.3): activity type, ALREADY-converted args
    (plain scalars), info hashref, task token, cancelled flag. `freeze`/`thaw`
    over `Storable`. No live core pointers / Cancellation / data converter
    cross the fork.
  - `Temporalio::Activity::ChildCancellation` — fork-safe cancellation token
    (no core FFI pointer); `is_cancelled`/`cancel`/`cancelled` mirror the real
    `Temporalio::Cancellation` but read a plain Perl flag the parent serialized.
  - `Temporalio::Activity::Pool` — the fork pool. `init_code` closes inherited
    parent handles BY FILEHANDLE (not fd number) + loads activity modules;
    `code` (`_child_dispatch`) thaws the invocation, looks the body up in the
    fork-copied registry, reconstructs a minimal Context, runs the body under
    `local $...::CURRENT`, and returns `{ ok, result|error, heartbeats }`.
- Dispatcher routing: `ActivityDispatcher` gained a `pool` param and a
  `_run_in_pool` method that builds the Invocation (converted args + info +
  cancellation flag) and `await $pool->invoke`. `_handle_start` branches on
  `$def->{sync}`.
- Worker wiring: `Temporalio::Worker` builds the pool lazily in
  `_build_activity_dispatcher` only when `$activity_registry->has_sync_activities`
  (new registry helper), with `inherited_fhs => [ $runtime->read_handle ]` (the
  shim wakeup fd) and a `heartbeat_relay` that calls `_record_heartbeat`. Added
  the `sync_activity_workers` field (spec section 8.1, default 4). The pool is
  closed on `run` teardown so no orphaned children linger.
- RED (P2.5.1): `sdk/t/unit/activity_pool.t` — 6 subtests: invocation
  serialize/round-trip, T-act-6 (sync body in a forked child returns its
  result, pid != parent), T-act-10 (child closes the inherited eventfd — probed
  via `/proc/self/fd` link, asserts the kernel eventfd object is gone),
  heartbeat relay (child heartbeat reaches the parent spy, decodes to a
  `coresdk.ActivityHeartbeat`), cooperative cancellation (parent flag ->
  `$ctx->cancellation->is_cancelled` true in child), dispatcher routing (sync ->
  pool spy / async -> main loop).
- Verify (P2.5.4): pool.t green (6 subtests); full `prove -lj4 t` -> 29 files,
  179 tests, exit 0 (was 28/173). No orphaned perl workers after the run.

## Reference grounding (quoted sources)

- **sdk-python `temporalio/worker/_activity.py`**: confirms the cross-process
  model. `_execute_sync_activity` (`:926`) is a top-level picklable function
  that re-establishes `temporalio.activity._Context` in the child and runs
  `fn(*args)`. `_MultiprocessingSharedStateManager` (`:1049`) owns a
  cross-process `_heartbeat_queue = mgr.Queue(1000)` (`:1059`); heartbeats are
  enqueued in the child and the PARENT drains the queue to perform the real
  heartbeat — exactly our "child relays, parent performs the FFI heartbeat"
  design. `SharedHeartbeatSender.send_heartbeat(task_token, *details)` (`:1040`)
  is the picklable child-side handle. Python uses a Manager queue (separate
  server process); we collect-and-return because IO::Async::Function's fork
  worker renumbers/closes spare fds (see Lessons).
- **sdk-ruby `lib/temporalio/worker/activity_executor/`**: Ruby's executors are
  THREAD-based (`thread_pool.rb`, `fiber.rb`), not fork-based — so Python is the
  closer analog for our fork model. Ruby confirmed the routing shape (sync vs
  async executor selection) but not the fork mechanics.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute P2.5 (Pool.pm + dispatcher routing + cross-fork invocation struct), FD hygiene as the central correctness property, heartbeat relay parent<-child, coop cancel parent->child, MUST-match vs sdk-python/sdk-ruby | Spec section 9.4 + reference reads; RED 6-subtest unit; sync flag plumbing across Definition/Attributes/FunctionDefinition/registry; Invocation + ChildCancellation + Pool; dispatcher `pool` routing; Worker pool wiring + teardown; three fork-behavior debug spikes; full suite; todo; summary; commit; push | Suite 29 files / 179 tests exit 0; T-act-6/T-act-10 + heartbeat relay + coop cancel + routing green; no orphaned children |

## Efficiency Insights

**What went well:**
- The injectable design from P2.4 paid off: the dispatcher routing test used a
  `FakePool` spy (no real fork), and the pool's `heartbeat_relay` is an injected
  coderef, so 5 of 6 subtests are deterministic and only the 3 fork-exercising
  subtests pay the fork cost.
- Closing inherited handles BY FILEHANDLE (not fd number) was the right call —
  it sidesteps IO::Async::Function's fd renumbering entirely.

**What could improve:**
- I initially built the heartbeat relay over a parent-side pipe whose write fd
  the child inherited. Cost two debug spikes to discover IO::Async::Function's
  fork worker closes/renumbers spare fds (the inherited write fd was EBADF in
  the child). Switched to collect-in-child / relay-on-return. Should have probed
  IO::Async::Function fd survival BEFORE designing a live cross-fork pipe.
- Re-hit the P2.4 `$loop->await($f)` returns the Future (not its value) trap in
  the pool test — fixed with a `run_loop` helper (`$loop->await; $f->get`).
  The lesson existed; I should have reached for the helper idiom immediately
  for any fork-parking Future.

**Course corrections:**
- T-act-10 redesigned mid-flight: a bare "read fd number N fails EBADF" probe is
  unreliable because IO::Async::Function reuses low fd numbers in the child (fd
  3 became a `Data.pm` handle). The robust assertion is "the parent's eventfd
  KERNEL OBJECT is gone from the child" — probed via `/proc/self/fd/N` symlink
  (must not be `anon_inode:[eventfd]`).

## Process Improvements

- Heartbeat semantics for sync activities are now collect-in-child /
  relay-on-return: each `heartbeat()` in a forked child pushes a frame onto a
  per-invocation in-child collector; `_child_dispatch` returns the frames with
  the result and the parent's `invoke` relays each to the real FFI heartbeat.
  This is correct at unit level and avoids IO::Async fd fragility; the v0.1
  limitation is that heartbeats are delivered at activity completion rather than
  mid-flight. A future enhancement could use a Manager-style side process (as
  sdk-python does) for real-time heartbeats — noted for Phase 3+ if a
  long-running heartbeating sync activity needs it.

## Observations

- `Temporalio::Activity::Pool` uses `local $...::Context::CURRENT` (not
  `dynamically`) in the child because the child body runs synchronously — there
  is no `await` to cross, so `local` is correct and `Syntax::Keyword::Dynamically`
  is unnecessary there (it IS required on the async-loop path in the dispatcher).
- The fork pool only forks when sync activities are registered
  (`has_sync_activities`); an all-async worker pays no fork cost.

## Suggested Skills for Next Session

- P3.1 (Workflow::Definition + attribute registration) is pure-Perl SDK
  internals: the four spike-verified attribute-handler constraints (spec
  section 10.1), `:Run`/`:Signal`/`:Query`/`:Update`/`:Init` registration, and
  the WorkflowRegistry. No matching skill — `temporal:temporal-developer` is
  end-user usage, not SDK internals. Heed the lessons.md F::AA-one-:isa-per-file
  and bare-class-subs-in-main:: rules when authoring the new class files.
