# Session Summary: R1+R21 Runtime Shutdown Drain Barrier and Pending-Future Failure

**Date**: 2026-07-08
**Duration**: ~25 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-moderate (full suite + cargo test runs)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (step complete, suite green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R1+R21, four sub-items)

## Key Actions

- RED: created `sdk/t/unit/runtime-shutdown-drain.t` with three GR5 guard-assertion subtests: barrier defers the queue free until an enqueued completion settles, a never-completing pending future fails with a typed shutdown error (no hang), and the single observable order barrier -> fail-pending -> queue-free.
  All three failed against the old code for the documented L1/L18 reasons (queue freed with an undrained entry, future left pending forever).
- GREEN: added `outstanding_count` and `fail_all_pending($error)` to `Temporalio::Core::Callback` (settles and clears the `$pending` registry); rewired `Temporalio::Runtime::shutdown` step 2 through a new `_settle_callbacks_and_free_queue` helper that drains until outstanding hits zero (bounded by the new `our $SHUTDOWN_DRAIN_TIMEOUT = 2` package knob), fails the rest with `Temporalio::Exception::Runtime`, then frees the queue.
- REFACTOR: the ordered sequence lives in the one helper with a comment block citing L1/L18 and the ext: trampoline traces (206-227, 368-392, 1684-1689); POD updated in Runtime.pm (shutdown ordering + timeout knob) and Callback.pm (two new methods).
- Verify: `cargo test` in `ext/temporalio-perl-bridge` green (27 passed, no shim change needed); `prove -lj4 t` green (105 files, 556 tests); `prove -lj4 xt` green (314 tests).
- Incidental: `ext/temporalio-perl-bridge/Cargo.lock` picked up the mechanical 0.1.0 -> 0.2.0 crate-version sync from running cargo test; committed with this step to keep the tree clean.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R1+R21 | Step complete, one commit |

## Efficiency Insights

**What went well:**
- The existing `callback.t` conventions (trampoline invocation through `*_callback_ptr`, `disable_free=1` crafted ByteArrays, `local *FFI::sub` spies) transplanted directly into the new test; no new harness needed.
- Making `$SHUTDOWN_DRAIN_TIMEOUT` a package variable let the never-completes subtests shrink the barrier to 0.2s, keeping the file at ~4s wall.

**What could improve:**
- The barrier polls with `Time::HiRes::sleep(0.01)` rather than re-arming the fd watcher; fine for a bounded shutdown window, but worth revisiting if shutdown latency ever matters.

**Course corrections:**
- None; the plan step mapped cleanly onto the code.

## Observations

- The residual race (a trampoline firing between fail-pending and queue-free for a callback that never delivered) is not closable from the Perl side alone; the bounded barrier plus settled futures is the GR5 guard the spec asks for. Full quiescence would need core runtime free to precede queue free, which inverts the documented teardown order.
- Suite-wide effect to watch: any future test that shuts a runtime down with outstanding callbacks now pays up to 2s of barrier and gets failed futures instead of silent pends. The full suite showed no fallout.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: next step (R2) continues the FFI memory-safety cluster.
