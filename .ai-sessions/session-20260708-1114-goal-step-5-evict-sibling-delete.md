# Session Summary: R16 Make Evict Iteration Safe Against Sibling Deletion

**Date**: 2026-07-08
**Duration**: ~15 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (two scratch probes, one RED/GREEN cycle, one full-suite run, one xt run)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (step complete, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R16, four sub-items)

## Key Actions

- Re-established finding L6 empirically before writing the test (the step-45 probes are gone from the tree): two scratch scripts drove the replay harness and called `evict` directly.
  A `WfDef::WaitAnyRace` run (activity + timer parked on `Future->wait_any`) croaked in `evict`; a single-activity `WfDef::ActivityCaller` run (self-delete only) survived, matching the finding's blast radius exactly.
- On this perl (5.38.2) the freed sibling alias does not surface as the classic "Use of freed value in iteration" croak: the deleted `$pending_timers` slot reads back as undef and the loop dies with "Can't call method \"is_ready\" on an undefined value" at the pre-fix Runner.pm:1537.
  Same root cause, different manifestation; the test and code comments document both forms.
- RED: created `sdk/t/replay/evict-sibling-delete.t` with two subtests.
  The sibling case drives the real `WorkflowDispatcher` (the workflow_poll_loop.t shape) so the test literally asserts the eviction completion is SENT: init parks WaitAnyRace with both pending tables populated, then a RemoveFromCache activation must not die, must drop the runner, and must send the empty-success completion.
  The self-delete case pins ActivityCaller's own-entry deletion as survivable so the fix cannot regress the simple path.
  Pre-fix: sibling subtest failed for the documented reason (evict croaked, no second completion); self-delete passed.
- GREEN + REFACTOR (one motion, the refactor is the code-trace comment): `evict` in `Workflow/Runner.pm` now iterates copied snapshots (`my @pending_futures = (values %pending_activities, ...)`) instead of the aliased `values` lists.
  The child-workflow and Nexus handle loops in `evict` got the same snapshot treatment: a handle's cancel de-registers its seq (the documented reason `_apply_cancel_workflow` snapshots `keys` at the pre-fix :2199/:2212), so they carried the identical latent hazard and the spec's required behavior is "eviction always completes".
  Comments cite finding L6 / spec R16, the pre-fix trace :1532-1538, the sweeps :2199/:2212, and both step-45 probe names.
- Verify: `prove -l t/replay/evict-sibling-delete.t` green; full `prove -lj4 t` green (109 files, 568 tests, integration ran live against a dev server); `prove -lj4 xt` green (314 tests). Not shim-touching, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R16 | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Probing the mechanism first (10 lines against the replay harness) pinned the exact croak message before the test existed, so the RED test asserted the right thing on the first run and the failure was the documented one.
- Reusing existing fixtures (`WfDef::WaitAnyRace`, `WfDef::ActivityCaller`) and the workflow_poll_loop.t dispatcher-builder shape meant zero new fixture files.

**What could improve:**
- First draft used bare `dies { ... }`; this repo's Test2::V1 style is `T2->dies(sub { ... })`. Check the local idiom before writing assertions.

**Course corrections:**
- The plan scoped the snapshot to the flattened future loop (:1532-1538); the child/nexus handle loops two paragraphs down iterate the same way with the same delete-in-continuation hazard, so the snapshot was applied to all three evict loops (still within R16's "eviction always completes" required behavior).

## Observations

- On 5.38.2, deleting a hash entry whose value slot a foreach holds aliased yields an undef alias and a method-call-on-undef croak rather than the "Use of freed value in iteration" message; grepping only for the classic message would miss this manifestation.
- `Future->wait_any` turns any component failure into a loser-cancel of the remaining components, so the runner's fail-with-Cancelled cancel overrides (activity, timer, condition futures) make ANY paired await a sibling-delete chain during evict.
- The dispatcher-based test shape (injected completer collecting completion bytes) is the right tool when the assertion is "a completion was actually sent", which a bare Runner harness cannot express.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: the next step (R4, per-instance activity pool state) is worker/activity-execution territory.
