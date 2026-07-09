# Session Summary: R43 Core-Engaged Replay Nondeterminism Detection

**Date**: 2026-07-09
**Duration**: ~45 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: medium (heavy cross-repo reference reading: c-bridge source, sdk-core replay module, sdk-python replayer; two full-suite runs; no cargo)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R43 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (finding R14 / spec R43: `Test/WorkflowReplay.pm` replayed through the Perl runner only, while README promised nondeterminism detection through replay)

## Key Actions

- Direction decision (R43 is a decision step): IMPLEMENT, not scope.
The pinned C bridge header exposes the core replayer (`temporal_core_worker_replayer_new` :1073, `temporal_core_worker_replay_push` :1078, `temporal_core_worker_replay_pusher_free` :1076) and `nm -D` confirmed the installed `Alien::Temporalio::Core` lib exports all three symbols, so core's history comparison is reachable with zero shim/cargo work.
The dispatcher note that R95 (resolved: real from-history/batch replayer) will need this wiring settled the tie.
The temporal-docs MCP was not available in this session; the `temporal:temporal-developer` skill plus direct source reading (c-bridge `worker.rs:975-1062`, sdk-core `replay/mod.rs`, sdk-python `worker/_replayer.py`) served as the ground-truth input the spec's test notes call for.
- RED: new `sdk/t/replay/nondeterminism.t` hand-builds a `temporal.api.history.v1.History` (the sdk-core `single_timer_wf_completes` canned shape, 10 events) and asserts three things: the recording workflow (`WfDef::TimerSleeper`) replays clean, a mutated workflow (`WfDef::Constant`, completes without starting the recorded timer) raises `Temporalio::Exception::Nondeterminism`, and `replay_history` enforces the typed-argument strictness rule.
Confirmed RED: no such method.
- GREEN in three layers:
`Core/FFI.pm` gained the two by-value records (`WorkerReplayerOrFail`, `WorkerReplayPushResult`), the `TemporalCoreWorkerReplayPusher` opaque alias, and the three synchronous attach entries.
`Worker/WorkflowDispatcher.pm` gained an optional `on_eviction` hook (sdk-python `on_eviction_hook` parity): `_has_eviction` became `_eviction_job` so the `RemoveFromCache` job's reason/message reach the hook before the empty completion is sent.
`Test/WorkflowReplay.pm` gained `replay_history`: packs replay worker options (python parity placeholders), builds the replay worker, reuses the live `WorkflowDispatcher` + `PollLoop` against it, pushes the one history, waits on the eviction future (60s guard), tears down in python's order (pusher free first, then initiate/finalize/free), and maps eviction reasons (3 NONDETERMINISM raises; 1 CACHE_FULL / 5 LANG_REQUESTED are the benign end-of-replay reasons; anything else is a Runtime error).
All bridge modules load lazily inside the method so activation-pushing users keep the native-free contract.
- Mid-verify fix: `Future->wait_any` cancels its losers, which killed the in-flight eviction dispatch ("Suspended async sub ... lost its returning future"); both raced futures now ride in as `->without_cancel` views (the lessons.md 2026-07-08 shield pattern).
- REFACTOR: R14/direction comment at the `field $runner` site distinguishing the two paths, POD for `replay_history` and `on_eviction`, README Replay section rewritten to describe exactly what each path checks.
- Verify: core genuinely detects the divergence (`TMPRL1100 Nondeterminism error: Complete workflow machine does not handle this event: HistoryEvent(id: 5, TimerStarted)`); full `prove -lj4 t` green (159 files, 726 tests, live integration included), `prove -lj4 xt` green (3 files, 410 tests).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (step R43, decision step) | Decided implement-over-scope, then full RED/GREEN/REFACTOR engaging core's replayer through the C bridge | Step complete, suites green |

## Efficiency Insights

**What went well:**
- Verifying symbol reachability first (`nm -D` on the installed Alien lib) before designing anything killed the scope-vs-implement question in one command and proved no cargo build was needed.
- Reading sdk-core's `replay/mod.rs` before writing the history fixture surfaced the two non-obvious contracts up front: histories must carry `original_execution_run_id` (core panics otherwise) and clean replays end in a LANG_REQUESTED eviction.

**What could improve:**
- The wait_any loser-cancel wart was already in lessons.md (2026-07-08 entry); checking lessons for "wait_any" before writing the race would have avoided one debug cycle.

**Course corrections:**
- Added `->without_cancel` shields to the eviction/poll race after the first green run surfaced the lost-future warning.

## Process Improvements

- None new.

## Observations

- The replay worker path reuses `WorkflowDispatcher` and `PollLoop` untouched except for the eviction hook; the live/replay parity the R14+R15 work established is what made this step small.
- R95 (from-JSON + batch replayer, resolved-implement) now reduces to: History-from-JSON parsing (`Protobuf::JSON` over the loaded schema should cover it), a multi-push loop over one replay worker, and a public result-aggregation surface; the core wiring, eviction mapping, and teardown order are done here.
- Next unchecked step is R45 (revive the dead Nexus integration test, `perl -c` RED first).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R45 rewrites a Nexus integration test against the real worker/connect APIs; the Nexus operation semantics ground truth helps.
