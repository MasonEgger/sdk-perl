# Session Summary: Goal Step 27 — ActivityDispatcher + PollLoop + Worker->run (P2.4)

**Date**: 2026-06-13
**Duration**: ~35 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (<$2 — reference-SDK + header + proto reads,
  one RED/GREEN/REFACTOR cycle, two debug spikes, two full suite runs)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P2.4.1 RED through P2.4.5 Verify in one commit.
  The async activity poll loop now exists: poll -> decode -> route start/cancel
  -> run body under a dynamically-scoped Context -> build + send completion;
  `Worker->run` drives it with the full initiate -> drain -> finalize -> free
  shutdown sequence. Sync activity fork pool remains P2.5.
- **Subagent dispatches**: this summary covers dispatch 27
- **Steps completed**: 5 of 5 P2.4 sub-items (P2.4.1–P2.4.5)

## Key Actions

- FFI attaches (P2.4.2): transcribed from the pinned C header
  (`temporal-sdk-core-c-bridge.h:1035,1048`) — `worker_poll_activity_task`
  `(worker, opaque user_data, opaque callback) -> void` (a
  TemporalCoreWorkerPollCallback, 'worker_poll' kind, returns serialized
  ActivityTask bytes or null/null ShutDown sentinel) and
  `worker_complete_activity_task` `(worker, ByteArrayRef completion, opaque,
  opaque) -> void` (a TemporalCoreWorkerCallback, 'worker' kind,
  fail-or-nothing). Both trampolines already existed in the shim — NO shim
  rebuild needed.
- Proto shapes (read, not from memory): `coresdk.activity_task.ActivityTask`
  is a `task_token` + oneof variant{start,cancel}
  (`activity_task/activity_task.proto:14-23`); completion is
  `coresdk.ActivityTaskCompletion{task_token, ActivityExecutionResult}` and
  `ActivityExecutionResult` is a oneof status{completed:Success,
  failed:Failure, cancelled:Cancellation, will_complete_async}
  (`activity_result/activity_result.proto:12-50`, `core_interface.proto:28-31`).
  Oneof accessor is `which_<oneof>` (here `which_variant` / `which_status`),
  per proto3-perl `Class/Generator.pm:174-178`.
- MUST-match poll->dispatch->complete cycle verified against sdk-ruby
  `internal/worker/activity_worker.rb`: `handle_task` branches start/cancel
  (`:82-91`); the running-activities map is task_token-keyed, added on start
  (`set_running_activity :57`), removed at completion (`remove_running_activity
  :69`, in `ensure`); `run_activity` (`:259-344`) determines the outcome —
  normal return -> `completed:Success{result}`; a CanceledError WITH a
  server-requested cancel -> `cancelled:Cancellation{failure}`; everything else
  -> `failed:Failure{failure}`. Our `_failure_completion` mirrors this:
  Cancelled exception + `$cancellation->is_cancelled` -> cancelled, else failed.
  Input/result payloads pass through the P1.6 `Converter::Data` codec path
  (decode on `start.input` per `:206-209`, encode on the completion result).
- RED (P2.4.1): `sdk/t/unit/activity_dispatch.t` — 9 subtests covering T-act-5
  (start runs async body, completes with encoded result), T-act-8 (die ->
  failed completion, ApplicationError type 'X' preserved on the wire), T-act-9
  (cancel resolves the activity's cancellation token; a body parked on
  `->cancellation->cancelled` resumes and completes cancelled), unknown-token
  cancel (warn+drop), codec decode/encode spy at the worker boundary, the
  running-activities token map (add on start / remove on completion),
  unregistered type -> failed, and the PollLoop shutdown-sentinel contract
  (T-wkr-4: dispatch until undef then return; empty source returns at once).
- GREEN (P2.4.2/3): `Temporalio::Worker::ActivityDispatcher` (decode + route +
  run-under-Context + build/send completion + token map),
  `Temporalio::Worker::PollLoop` (injectable poll source -> dispatcher loop,
  concurrent dispatch + drain-before-return), the two FFI attaches, and
  `Worker->run` wiring (validate -> activity poll loop -> initiate -> finalize
  -> free) with `shutdown` made loop-aware.
- REFACTOR (P2.4.4): `Temporalio::Worker::ActivityCompletion` — pure proto
  shaper with `success`/`failure`/`cancelled` builders, reusable by the
  workflow side later.
- Verify (P2.4.5): dispatch.t green (9 subtests); full `prove -lj4 t` -> 28
  files, 173 tests, exit 0 (was 27/164).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute P2.4 (ActivityDispatcher + PollLoop activity loop + FFI attaches + Worker->run), MUST-match vs sdk-ruby/python, dynamically-scoped Context across await, header-true poll/complete FFI | Header + proto + reference reads; RED 9-subtest unit; GREEN dispatcher/poll-loop/completion-builder + 2 FFI attaches + Worker->run/shutdown; two debug spikes (IO::Async await vs ->get; dynamically across Future->call); full suite; todo; summary; commit; push | Suite 28 files / 173 tests exit 0; T-act-5/8/9 + T-wkr-4 (unit) green |

## Efficiency Insights

**What went well:**
- The P1.6 `Converter::Data` (codec-aware `from_payloads`/`to_payloads`/
  `to_failure`) and P1.1 `Cancellation` made the dispatcher thin: decode,
  route, run, convert, build, send. The completion builder is ~15 lines of
  proto shaping.
- Injecting the completer + heartbeat recorder + poll source as coderefs let
  the entire dispatcher and poll loop be unit-tested with crafted protos — no
  live worker, no server.

**What could improve:**
- First RED run failed on a TEST bug, not a code bug: I used
  `$loop->await($f)` expecting the resolved value, but `IO::Async::Loop->await`
  returns the Future itself; the codebase pattern is `$f->get` (synchronous for
  in-memory futures, see `converter_data.t`). Cost one debug spike. Should have
  grepped the await idiom in existing tests before writing the helper.

**Course corrections:**
- The `dynamically` scope must wrap the `await` itself, not just the
  synchronous `_invoke` call. My first cut scoped `dynamically` inside a `do`
  block that returned the Future BEFORE the body ran, so a body parking on
  `await $ctx->cancellation->cancelled` lost `$CURRENT`. Moving `await` inside
  the `dynamically` block fixed it — that is exactly what
  Syntax::Keyword::Dynamically is for (restore-across-suspend/resume).
- The dispatcher must `use Temporalio::Activity ()` (not just
  `::Activity::Context`): the `context()`/`info()`/`heartbeat()` package
  functions activity bodies call live in `Temporalio::Activity`, and bodies die
  with "Undefined subroutine" if it is not loaded by the dispatcher.

## Process Improvements

- `Worker->run` and `shutdown` now cooperate: while `run` drives the loop,
  `shutdown` only INITIATES (so core returns the ShutDown sentinel from the
  next poll); `run` does the finalize + free on its way out once the loop has
  drained. For a never-run worker (P2.2 construction + validate only),
  `shutdown` still does the synchronous initiate + free directly (no finalize —
  it would deadlock with no loop driving the polls). The P2.2 finalize-deadlock
  lesson is now honored by construction.

## Observations

- `worker_record_activity_heartbeat` is the only SYNC FFI call in the worker
  path; `_record_heartbeat` wraps/reads/frees the returned error byte array
  exactly like `_ensure_worker` does for the worker-creation fail array.
- A full `Worker->run` happy-path needs a live server (the activity loop polls
  core), so the unit tests cover the dispatcher + poll loop in isolation and
  the PollLoop shutdown contract for T-wkr-4; the live integration lands with
  the Phase 3 end-to-end (P3.9) where a workflow actually schedules activities.
- `ActivityCompletion::success` passes `result => undef` for a void activity;
  proto3 encodes that as an absent field, matching the reference SDKs'
  `Success{result: nil}`.

## Suggested Skills for Next Session

- No matching skill for P2.5 (sync activity fork pool): `IO::Async::Function`
  fork pool, `init_code` FD hygiene (children MUST close the inherited eventfd/
  pipe + core handles — T-act-10 reads the parent eventfd from the child and
  expects EBADF), the heartbeat pipe relay back to the parent's FFI call, and
  cooperative cancellation across the fork. Reference ground truth: spec §9.4,
  sdk-ruby activity executors. The `temporal:temporal-developer` skill is
  end-user usage, not SDK internals.
