# Session Summary: Step R91, Raw Service Clients

**Date**: 2026-07-09
**Duration**: ~30 minutes
**Conversation Turns**: 1 (autonomous dispatch)
**Estimated Cost**: low (single step-executor dispatch; one Test2::V1 idiom fix after the first unit-test run)
**Model**: claude-fable-5

## Goal Context

- **Condition**: execute todo.md step R91 (raw workflow_service/operator_service handles over the c-bridge rpc-call surface, methods generated from the proto service descriptors, to _client.py:307-322 parity), one commit
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (R91.1 through R91.4 checked; full suite green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1

## Key Actions

- Pinned the parity target: Python `_client.py:307-322` accessors delegate to `service.py`'s per-service passthrough objects, whose per-rpc methods are GENERATED (`bridge/services_generated.py`), each funneling into the service client's `_rpc_call`.
The c-bridge dispatches by CamelCase rpc name (`client.rs` `call_workflow_service` / `call_operator_service` match arms; `TemporalCoreRpcService` Operator=2 already in the Perl `%RPC_SERVICE`).
- RED: `sdk/t/integration/raw_service_client.t`, one subprocess-guarded dev-server scenario: `$client->workflow_service->get_system_info` round-trips typed; `$client->operator_service` add/list/remove of a custom Keyword search attribute proves the operator request is formed and sent (the list reads the server's own state back); cross-service isolation pinned via `can()`.
Honest RED on the missing accessors.
- GREEN: moved the `_rpc_call` funnel body from `Client.pm` to `Connection::rpc_call` (matching Python, where the rpc call belongs to the service client); `Client::_rpc_call` is now a thin delegator that flips the retry default to 1 while `Connection::rpc_call` defaults retry 0 (Python's raw-service `retry=False`).
New handle classes `Temporalio::Client::{WorkflowService,OperatorService}` (one class per file, no `:isa`, signature-less `call`, per the F::AA parser lessons), each a thin connection wrapper.
`Core/Proto.pm` now also parses `temporal/api/operatorservice/v1/*.proto` as roots, so the operator messages and service descriptor exist.
- REFACTOR: `Temporalio::Client::RawService::install_rpc_methods` generates one snake_case method per descriptor rpc (117 workflow, 12 operator) into the handle package at first construction, passing the CamelCase rpc name plus the descriptor-resolved `response_class`; finding-1 comments at every touched site.
Deterministic pins in `t/unit/raw_service.t` (descriptor-vs-`can()` sweep of both services, wrapper arg passthrough over a classic blessed-hash fake connection, snake_case cases, unknown-service Runtime throw).
- Verify: `prove -lj4 t` green (191 files, 844 tests, live integration included); `prove -lj4 xt` green (432).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: R91, raw service clients | RED integration test, funnel move to Connection, descriptor-generated handle classes, unit pins, POD, todo check-off | Step complete, suites green, one commit |

## Efficiency Insights

**What went well:**
- Checking the c-bridge dispatch (`client.rs` match arms) BEFORE designing settled two questions at once: the rpc name format is CamelCase (Python's snake names are a pyo3-path artifact) and the operator arm covers exactly the 12 descriptor rpcs.
- `Protobuf::Schema` already indexes services (`schema->service($fqn)` returns `{name, input_type, output_type}` per method), so descriptor-driven generation needed zero parser work; only the operatorservice roots were missing from `Core/Proto.pm`.

**What could improve:**
- The first unit-test draft used bareword Test2 calls (`subtest`, `ok`) and died at parse; one conversion pass to `T2->` form fixed it. Writing `T2->` from the start would have saved the cycle.

**Course corrections:**
- None beyond the Test2 idiom fix; the live scenario passed on the first post-GREEN run.

## Process Improvements

- None.

## Observations

- Perl exposes exactly the two spec-required services (workflow, operator); Python also has cloud/test/health service objects.
The `%RPC_SERVICE` map already carries their discriminators and `Connection::rpc_call` accepts them via `service =>`, so adding handles later is one descriptor root plus one handle file each (test/health protos are not vendored today).
- The handles are built fresh per accessor call instead of cached: caching on the Connection would create a Connection-to-handle-to-Connection cycle and defeat the free-with-warning DESTROY path.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: R92 (WorkflowHandle get_update_handle) pins against Python `client/_workflow.py:978,1008` update-handle semantics.
