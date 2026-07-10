# Session Summary: R27+R38 Determinism-Guard Install Point and Override Accountability

**Date**: 2026-07-08
**Duration**: ~35 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one new subprocess-guarded integration test, unit test extensions, install/arm lifecycle split across three lib files; pure Perl, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R27+R38 boxes complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (merged step R27+R38, findings R13/A15: guard install was compile-order blind and the process-global overrides had no documented lifecycle)

## Key Actions

- Root cause per finding R13: `CORE::GLOBAL` overrides only affect call sites compiled AFTER installation, and `Worker.pm` installed at worker construction, so any workflow module `use`d normally (before `Worker->new`) had unguarded `time`/`rand` call sites.
The Time::HiRes symbol-table overrides never had this problem (glob redefinition hits pre-compiled call sites too); only the six CORE::GLOBAL overrides were compile-order sensitive.
- The one install-point decision (per the plan NOTE, R27 and R38 decided together): the lifecycle is now two-stage.
`install()` (wiring the overrides) runs at `Temporalio::Workflow::Definition` load time via a file-scope call in Definition.pm; every workflow class must load the base before its `class :isa` statement (via `use Temporalio::Workflow` or the `:isa` auto-require), which precedes its method bodies, so the overrides always exist before workflow call sites compile.
New `arm()` (activating trapping) runs at Worker construction unless `disable_determinism_guard`; `_guarding()` now also requires `$ARMED`.
- The arm gate is what preserves the existing contracts: the replay harness never arms, so replay tests keep running fixtures that poke the time surface; the live default-ON / disable-able semantics are unchanged; installed-but-unarmed is a verified transparent passthrough even inside workflow context.
- R38 permanence decision: no uninstall/disarm (CORE::GLOBAL overrides cannot be cleanly removed from already-compiled call sites, and a process-global trap cannot disarm per-worker), documented explicitly per the spec's "or the POD states the permanence explicitly" arm.
Worker POD gained a "Determinism guard lifecycle" section; DeterminismGuard POD gained a Lifecycle section plus `arm`/`is_armed` entries; comments cite R13/A15.
- RED evidence: new `sdk/t/integration/determinism_guard_load_order.t` (SubprocessGuard template from repro_condition_timeout_rearm.t) requires `WfDef::IllegalTime` in the parent (compiled pre-fork, before any worker), runs it live with `nondeterminism_as_workflow_fail => 1`, and asserts the result await fails with the non-determinism message.
Pre-fix the workflow COMPLETED with a wall-clock epoch (1783558746) — the exact defect.
Unit RED: `determinism_guard.t` now asserts `is_installed()` purely from the `use Temporalio::Workflow ()` load (failed pre-fix) plus unarmed-passthrough-in-context, and a new R38 subtest constructs a Worker (FakeClient double from worker_new.t) and verifies time/rand/localtime/Time::HiRes::time behave stock outside workflow context while armed.
- Verify: `prove -lj4 t` green (147 files, 670 tests, integration live against the dev server), `prove -lj4 xt` green (318).
No fallout: a pre-GREEN audit greped all workflow-context SDK modules and every WfDef fixture for raw trapped builtins; only the deliberately-illegal fixtures (IllegalTime/IllegalRand/IllegalHiRes/UnsafeEscape) touch them.
- Cross-repo note (spec R27 acceptance): samples-perl requirement R1 (the determinism sample) is now satisfiable without sample-side load-order tricks, since guard coverage no longer depends on loading the workflow module after worker construction.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (R27+R38 merged step) | Full RED/GREEN/REFACTOR for the guard install/arm lifecycle (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Auditing the blast radius BEFORE GREEN (grep for raw time/entropy call sites in workflow-context lib modules and all WfDef fixtures) predicted zero downstream failures, and the full suite confirmed it — no late surprises this time (the R26 session's lesson applied).
- Realizing early that symbol-table overrides (Time::HiRes) are compile-order immune while CORE::GLOBAL ones are not scoped the fix to exactly the six builtins that needed the new install point.

**What could improve:**
- The verify-45 probe directory cited by the plan is ephemeral scratch that no longer exists; a few minutes went to confirming that (spec line 23 documents it). Plans citing probe paths should flag the scratchpad status inline.

**Course corrections:**
- First instinct was to keep a single install() doing both wiring and trapping at Definition load; that would have armed the replay harness and broken the disable knob. Splitting install (compile-time concern) from arm (runtime concern) resolved both R27 and R38 with one mechanism.

## Process Improvements

- When a fix moves a process-global hook's install point earlier, split "the hook exists" from "the hook acts" — the compile-order requirement only constrains the former, and the latter can stay on the old opt-in trigger to avoid semantic fallout.

## Observations

- Installed-but-unarmed passthrough in workflow context is now a pinned contract (the replay-harness freedom), asserted by the first unit subtest — worth remembering if anyone later proposes arming at Definition load.
- Next unchecked step is R29 (break the start-future ownership cycle in ChildWorkflowHandle/NexusOperationHandle; unit weak-ref liveness test, adapts probe_l5_cycle).

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R29 touches child-workflow and Nexus operation handles; the patterns reference frames the handle semantics the ownership-cycle fix must preserve.
