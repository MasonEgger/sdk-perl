# Session Summary: R34+R61 Ephemeral-Port Race Removal and Net::EmptyPort Deletion

**Date**: 2026-07-08
**Duration**: ~35 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low-medium (pure Perl work, no cargo; the verify phase ran the live integration suite three times plus the full suite)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four boxes of the merged R34+R61 step complete in one commit, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (finding T-flake / spec R34: the DevServer select-then-free port TOCTOU behind the known updates.t `prove -j4` flake; finding L29 / spec R61: the Net::EmptyPort cpanfile phase misclassification, which collapsed to deletion)

## Key Actions

- Verified the port-0-passthrough option against the pinned sources before writing anything: the C header documents `TestServerOptions.port` as "0 means default behavior"; core's `get_free_port` (crates/sdk-core/src/ephemeral_server/mod.rs) binds :0 and then parks the pick in TIME_WAIT via a self-connect closed from the server side, so the kernel cannot re-issue it while an explicit bind still succeeds; the actual bound endpoint returns through the start callback's `success_target`, which DevServer already reads as `$started->{target}`.
That made port-0-passthrough (the plan's preferred option) available, and R61 collapsed to deleting the dependency.
- Confirmed the pre-fix hazard in the installed Net::EmptyPort: the no-args `empty_port()` branch binds :0, reads the kernel's pick, CLOSES the socket, and returns the number, with no TIME_WAIT reservation. DevServer then freed that port for anyone to grab before sdk-core's CLI could bind it.
- RED, deterministic: new `sdk/t/unit/emptyport_range.t` (the durable adaptation of the step-45 probe `verify-45/memsafe-infra/emptyport_range.pl`, which no longer exists in the tree) with four subtests: the probe claim (a bind(:0) pick lands inside /proc/sys/net/ipv4/ip_local_port_range; observed 57265 in 32768-60999), a port-capture pin (wraps `TestServerOptions->new` and spies `issue_async` so no bridge call is issued; asserts port 0 rides the bridge, the target is the bridge-reported endpoint, and an explicit `port` option still passes through), a source audit (no Net::EmptyPort load statement remains in DevServer.pm), and the R61 dependency audit (every Net::EmptyPort use site under lib/ needs a runtime-phase cpanfile declaration, t//xt/ sites need test phase, and a declaration with no use site is stale).
Confirmed RED: three of four subtests failed for exactly the documented reasons (Perl-side pick nonzero, load statement present, lib/ use site declared test-phase only).
- RED, acceptance scenario: new `sdk/t/integration/devserver_concurrent_start.t` (skip_all offline): three iterations of four dev servers started concurrently, each inside a SubprocessGuard-guarded child that forks four grandchildren; each grandchild requires the SDK stack only after its own fork (the guard's no-Tokio-before-fork contract), boots a server on a unique namespace, connects, and starts a workflow in that namespace as the cross-connect probe (namespace-not-found against any sibling server); the guarded child asserts four successes on four distinct ports.
The pre-fix failure mode is probabilistic, so this file is the pressure harness rather than the deterministic RED; it passed pre-fix (12s wallclock) and its comment says so.
- GREEN: `Test/DevServer.pm` default port is now 0 (`delete $options{port} // 0`), the `use Net::EmptyPort ()` line is gone, and the POD describes the core-side pick; `sdk/cpanfile` no longer declares Net::EmptyPort in any phase.
The REFACTOR comment at the port site cites T-flake/R34, the chosen strategy (port-0 passthrough with the bound endpoint read back), the TOCTOU it replaces, and the R61 coupling, and points at t/unit/emptyport_range.t.
- Verify: `prove -lj4 t/integration` green twice in a row (37 files, 94 tests, updates.t among them, ~139s each); full `prove -lj4 t` green (158 files, 723 tests); `prove -lj4 xt` green (322 POD tests). No flake reproduced in any -j4 pass. Not shim-touching, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item (merged step R34+R61) | Full RED/GREEN/REFACTOR for the port race + dependency deletion (four boxes, one commit) | Step complete, suites green |

## Efficiency Insights

**What went well:**
- Reading core's `get_free_port` and testing.rs before choosing a strategy settled the pick in minutes: the plan's preferred option was fully supported, so no retry-on-bind machinery was needed.
- The wrap-not-replace mock on `TestServerOptions->new` (capture the args, delegate to the real record constructor) pinned the bridge-bound port without any FFI stubbing beyond the R3 test file's existing issue_async spy pattern.

**What could improve:**
- The blanket `qr/Net::EmptyPort/` source audit tripped on the fix's own code-trace comment; it had to be narrowed to load statements. Audit assertions that grep for a removed module should target `use`/`require` from the start, since evergreen comments legitimately name what was removed.

**Course corrections:**
- First GREEN run failed only on the blanket source-audit regex above; narrowed and re-ran.

## Process Improvements

- None new.

## Observations

- The dependency-audit subtest is deliberately general: if Net::EmptyPort is ever reintroduced anywhere in sdk/, the test forces the cpanfile phase to match the use site, so R61's failure mode cannot quietly return.
- The step-level flake criterion (updates.t under one full -j4 run plus two -j4 integration runs) is covered; the goal-level "ten `prove -lj4 t` runs" criterion (plan line 1458) remains for the convergence phase.
- Next unchecked step is R49 (END-block dev-server teardown across ~30 integration files, driven by a new xt static probe). devserver_concurrent_start.t keeps its teardown inside the guarded grandchildren, where an END block cannot apply; if R49's xt probe greps for `Test::DevServer->start` sites it must not flag files whose servers live only in forked children that exit via `POSIX::_exit`.

## Suggested Skills for Next Session

- None specific: R49 is static-analysis Perl over t/integration/*.t; no stack skill in the list covers it better than the plan text and CLAUDE.md already do.
