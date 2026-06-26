# Session Summary: B6 C-NEXUS enable Nexus serving + wire the task poller (#11)

**Date**: 2026-06-26
**Duration**: ~50 minutes
**Conversation Turns**: ~20
**Estimated Cost**: ~$4
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Condition**: B6 cluster (#11) — worker hardcodes `enable_nexus => 0`; caller's execute_nexus_operation blocks forever
- **Mode**: step (single B6 cluster: B6.1 RED, B6.2 GREEN, B6.3 REFACTOR, B6.4 Verify)
- **Outcome**: converged
- **Subagent dispatches**: 1 (this one)
- **Steps completed**: 4 of 4 (B6.1-B6.4)

## Key Actions

- Diagnosed scope: UNLIKE B5 local activities (flag flip, rode the existing
  `poll_activity_task` path), Nexus needed THREE Perl-side additions but NO shim
  change. The pinned core C bridge already exports
  `temporal_core_worker_poll_nexus_task` + `temporal_core_worker_complete_nexus_task`
  (confirmed via `nm -D` on the installed `libtemporalio_sdk_core_c_bridge.so`),
  with the same callback types as the activity pair, so the existing trampoline
  pointers serve them. The `NexusDispatcher` already existed complete (start/cancel/
  error routing) with zero callers.
- B6.1 RED: wrote `sdk/t/integration/repro_nexus.t`, SubprocessGuard-wrapped,
  self-provisioning a Nexus endpoint via the temporal CLI against a dev server
  started with `--dynamic-config-value system.enableNexus=true`, so it runs BY
  DEFAULT (no env gating). Confirmed RED: the caller workflow ran but the Nexus
  operation never resolved (45s await timeout), child exited 1.
- B6.2 GREEN: added FFI bindings for the two nexus functions; added
  `_poll_nexus_task` / `_complete_nexus_task` over the callback bridge; added
  `_build_nexus_dispatcher`; wired a `PollLoop` for Nexus into `run()` only when
  `_nexus_enabled`; flipped `enable_nexus => $self->_nexus_enabled`.
- B6.3 REFACTOR: gated everything on `_nexus_enabled` (true iff
  `$nexus_registry->services` is non-empty); comment cites #11; a non-Nexus
  worker neither enables the flag nor starts the loop.
- B6.4 Verify: repro resolves in ~4s; full `prove -lj4 t` green (533 tests, 95
  files); author POD tests green; gated `nexus.t` skips cleanly; non-Nexus
  integration tests unaffected.
- Recorded the diagnosis in `ROOT-CAUSE-MAP.md` (#11 row).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Execute B6 cluster per system prompt | Diagnosed scope, RED test, GREEN wiring, REFACTOR gating, full verify | All 4 sub-steps done, suite green |

## Efficiency Insights

**What went well:**
- `nm -D` on the installed lib up front settled the shim-vs-Perl question fast —
  no cargo/Alien rebuild needed, saving a multi-minute memory-guarded build.
- Reused the existing `NexusDef::Handler` / `WfDef::NexusCallerIntegration`
  fixtures and the `SubprocessGuard` pattern from B5.

**What could improve:**
- First RED run used the full class name `WfDef::NexusCallerIntegration` as the
  start type, hitting a "workflow type not registered" mismatch (the registered
  name is the class basename `NexusCallerIntegration`). The gated `nexus.t` has
  the same latent bug but never runs to catch it.

**Course corrections:**
- Fixed the start type to the basename so the RED failure was the genuine Nexus
  hang, not a name mismatch.

## Process Improvements

- When a repro needs a Nexus endpoint, self-provision it via the temporal CLI
  (`operator nexus endpoint create --target-namespace/--target-task-queue`)
  against a dev server started with `--dynamic-config-value system.enableNexus=true`,
  rather than env-gating and skipping. Keeps the repro runnable by default.

## Observations

- The default workflow type name is the class BASENAME when the `:Run` method is
  named `run` (Definition.pm). Pass the basename to `start_workflow`, not the
  full `WfDef::` class.
- Core rejects `worker_poll_nexus_task` when `enable_nexus` is off, so the Nexus
  poll loop MUST be conditional on the same registered-services gate as the flag.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — B7 (worker inbound interceptor chains, #10) is
  next; it needs Temporal worker-dispatch semantics.
