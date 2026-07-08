# Session Summary: R23+R50 Shared Cancellation Future Survives wait_any

**Date**: 2026-07-08
**Duration**: ~25 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (two-line product fix plus one new helper module and two test files; one full-suite run, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R23+R50 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (merged step R23+R50, findings R2/=A4=L31a and T2: shared cancelled() future poisoned by a Future->wait_any loser sweep, plus zero direct ChildCancellation coverage)

## Key Actions

- Re-ran the R2 probe inline (verify-45/ is gone): two wait_any loser sweeps against `cancelled()`, then a real `cancel`; a fresh consumer saw `ready=1 done=0 cancelled=1`, the poisoned husk.
The mechanism: wait_any cancels losers, a cancelled future counts as ready, so `cancel()`'s `!$future->is_ready` guard skipped `->done` forever.
- Probed the `->without_cancel` fix shape before writing tests: a wrapper cancel leaves the source pending, a wrapper of a done source is done, and a DROPPED wrapper still fires its `on_done` when the source resolves later (load-bearing for Activity/Pool.pm:252, which chains and discards the future).
Also proved `\$field` refs mutate the instance slot under `feature 'class'` on 5.38.2, which the shared helper relies on.
- RED: extended `sdk/t/unit/cancellation.t` (double wait_any-loser race, then cancel; fresh AND held consumers must observe) and created `sdk/t/unit/child_cancellation.t` (construction defaults, `cancelled => 1`, cancel observation/idempotence, the R19 poll hook, and the same race shape).
Both race subtests failed pre-fix for exactly the documented reason; all other subtests passed.
- GREEN: one line per class, `return $future->without_cancel;` in `Cancellation.pm` and `Activity/ChildCancellation.pm`.
- REFACTOR: extracted the identical derivation into new `sdk/lib/Temporalio/Common/CancellationFuture.pm` (`consumer_future(\$source, $cancelled)`), pure Perl with only a Future dep so ChildCancellation keeps its no-FFI design isolation; both classes route through it via a `\$field` ref.
POD in all three modules documents the safe-to-race contract, citing R2/T2 and spec R23/R50.
- Audited every `cancelled()` consumer before committing to per-call instances: Activity/Pool.pm:252 (chain-and-drop, covered by the dropped-wrapper probe), activity_dispatch.t:157 (await holds a ref), pool-live-cancel.t:75 (held future resolves via the shared source). All compatible; pool-live-cancel.t and activity_dispatch.t re-run green as spot checks.
- Verify: `prove -lj4 t` green (143 files, 652 tests, integration live against the dev server); `prove -lj4 xt` green (316, up 2: the new module's NAME + consumer_future POD). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (merged R23+R50) | Full RED/GREEN/REFACTOR for the cancellation-future unit of work (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Probing all three load-bearing behaviors (poison mechanism, without_cancel semantics including the dropped-wrapper case, field refs) as one-liners before writing any code meant zero fixture surprises; RED failed exactly as predicted on the first run.
- lessons.md entry 13 already documented wait_any's loser-cancel and the without_cancel shield precedent (Test/Worker.pm:38), which settled the fix shape immediately.

**What could improve:**
- Nothing notable; the plan's file paths and probe shape were accurate as written.

**Course corrections:**
- None.

## Process Improvements

- When changing a method from returning a shared object to per-call instances, grep every call site for identity or lifetime assumptions BEFORE writing GREEN; the chain-and-drop consumer (Pool.pm:252) was only safe because Future's without_cancel keeps the wrapper alive through the source's callback chain, and that needed an explicit probe.

## Observations

- `Future->done`/`->fail` on a cancelled future being a silent no-op (lessons entry 13) is the same root mechanism as this defect; R23 is the token-side face of the L3/R3 bridge-future story, now both shielded with without_cancel.
- The new `Temporalio::Common::CancellationFuture` deliberately lives outside `Temporalio::Cancellation`'s namespace so `Activity::ChildCancellation` can load it without pulling `Temporalio::Core::FFI` into the fork-safe child token.
- Next unchecked step is R24 (enforce read-only context and writability asserts uniformly: four bypassing APIs plus query handlers never entering read-only context).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R24 is query/read-only workflow-context semantics; Python read-only parity (`../sdk-python`) is the ground truth.
