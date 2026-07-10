# Session Summary: Schedule data classes + Client methods (P8.1)

**Date**: 2026-06-24
**Duration**: ~35 minutes
**Conversation Turns**: 1 (autonomous step-executor dispatch)
**Estimated Cost**: ~$3 (Opus, large-context reads of spec/protos/reference SDK)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: Phase 8 scheduling — P8.1 schedule data classes + client methods green (prove -lj4 t/unit exits 0; full prove -lj4 t green)
- **Mode**: step
- **Outcome**: converged (this step)
- **Turn count**: 1
- **Subagent dispatches**: 1 (this executor)
- **Steps completed**: 3 of 3 P8.1 sub-items (P8.1.1/.2/.3) folded into one commit

## Key Actions

- Wrote `sdk/t/unit/schedule_types.t` (T-sched-unit): Range inclusive/inclusive (no +1), Calendar default-range injection (second=[0], day_of_month=[1..31], month=[1..12], day_of_week=[0..6], year empty), Spec/Interval/State/Schedule proto field remaps, OverlapPolicy string->enum, Backfill start-exclusive/end-inclusive, Action reuse/cron kwarg rejection. Confirmed RED first.
- Wrote `sdk/t/unit/schedule_request.t`: get_schedule_handle (no RPC), create_schedule request shape (initial_patch only on trigger/backfills, trigger overlap from the schedule policy), limited/remaining invariant -> Argument pre-RPC, unknown-kwarg -> Argument, ALREADY_EXISTS -> ScheduleAlreadyRunning, list_schedules lazy iterator + ListSchedulesRequest shape. Used the established glob-override `_rpc_call` mock pattern from `workflow_handle_result.t`.
- Built the flat `Temporalio::Schedule::*` data-class tree: Range, Calendar, Interval, Spec, State, Policy (with shared OverlapPolicy coercion), Backfill, Action (+ Action::StartWorkflow async `_to_proto`), Schedule, Update (+ Update::Input), Info, Description, ListDescription, plus the umbrella `Schedule.pm` with short constructors.
- Added three Client methods: `get_schedule_handle` (no RPC), async `create_schedule` (invariant check, initial_patch builder, ALREADY_EXISTS re-map via new `_is_already_exists` helper), and `list_schedules` (lazy iterator). Added `Client/ScheduleHandle.pm` (minimal id/client readers; ops are P8.2), `Client/ScheduleListIterator.pm`, and `Exception/ScheduleAlreadyRunning.pm`.
- Verified: prove -lj4 t/unit (31 files, 214 tests) green; prove -lj4 t (59 files, 361 tests) green; prove -lj4 xt (POD coverage) green.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute next unchecked todo (P8.1) | TDD RED+GREEN+Verify in one commit | All schedule unit tests pass; full suite + author tests green |

## Efficiency Insights

**What went well:**
- Cross-checked default calendar ranges, the limited/remaining invariant, and the trigger-overlap-from-policy rule against sdk-python `client/_schedule.py` + `client/_impl.py` before coding, so those were right first time.
- Reused the proven per-object glob-override `_rpc_call` mock from `workflow_handle_result.t` instead of a `parent`-based subclass (which does NOT intercept `feature 'class'` method dispatch).

**What could improve:**
- The first request-test draft used a `parent`-subclass to stub `_rpc_call`; `feature 'class'` method dispatch ignored the glob-assigned override and hit the real bridge. Switched to the per-refaddr `%MOCKS` registry pattern. Should have reached for that pattern first.

**Course corrections:**
- The generated proto reader for the Schedule message `state` field is `state_` (a bare `state` collides with a base-class method), though `new({ state => ... })` still accepts the plain key. Adjusted `Schedule->_from_proto` and the test read to use `state_`.

## Process Improvements

- When stubbing a `Temporalio::Client` RPC in a unit test, use the per-object `%MOCKS` glob-override of `Temporalio::Client::_rpc_call` (see `workflow_handle_result.t`), not a `parent`-based subclass — `feature 'class'` method dispatch does not see subclass overrides installed by typeglob.

## Observations

- `Future->fail($exception_object)` keeps a blessed object intact across `await` for the `catch` in `create_schedule`; a `die $obj` inside an `eval { } / Future->fail($@)` wrapper did not surface the object cleanly in the test, so the duplicate-id test fails the RpcError directly.
- An ALREADY_EXISTS on CreateSchedule maps (via the section 7.5 table) to a generic RpcError with status_code 6 — the WorkflowAlreadyStarted special-case is keyed on Start/SignalWithStartWorkflowExecution only, so `create_schedule` re-maps code-6 RpcError itself.

## Suggested Skills for Next Session

- None required for P8.2 (ScheduleHandle ops + integration) — still pure-Perl client-side plus a dev-server integration test; reference `../sdk-python` / `../sdk-ruby` schedule handle source for the PatchSchedule/Update/Delete request shapes.
