# Session Summary: R13 Keep Query and Update Responses on Failure Completions

**Date**: 2026-07-08
**Duration**: ~20 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one fixture + one replay file, a surgical Runner.pm partition, one full-suite run, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (all four R13 boxes complete, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R13, finding R9: failure completions keep handler responses)

## Key Actions

- Verified the Python ground truth before writing assertions, as the spec's test note demands: `_set_workflow_failure` (`../sdk-python/temporalio/worker/_workflow_instance.py:2567-2576`) APPENDS `fail_workflow_execution` via `_add_command()` to the already-accumulated `successful.commands` and clears nothing, so query and update responses ride along in Python's failure completion. The old Perl comment claiming Python "adds only the fail command" was false, exactly as finding R9 said.
- RED: new fixture `sdk/t/lib/WfDef/FailingResponder.pm` (parks on wait_condition, throws ApplicationError when armed; handlers: `fail-now` signal, `timer-then-fail` signal that buffers a StartTimer first, `status` query, `finish-and-fail` update) and `sdk/t/replay/failure_keeps_responses.t` (3 subtests). Confirmed the three response-survival assertions fail pre-fix for the documented reason while the mutating-dropped and fail-command baselines pass.
- GREEN: `Workflow/Runner.pm` `_workflow_failed_completion` now partitions instead of clearing: `@commands = grep { _is_handler_response_command($_) } @commands` before emitting the fail command; the false Python comment replaced with the verified citation.
- REFACTOR: extracted the `_is_handler_response_command` predicate (respond_to_query or update_response) next to `_is_query_response`, comments cite spec R13 / finding R9 and the sdk-python source; updated the `_build_completion` POD bullet to state that responses survive and only state-mutating commands are dropped.
- Verify: new file green; full `prove -lj4 t` green (138 files, 633 tests, integration suite live against the dev server); `prove -lj4 xt` green (314). Pure Perl step, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R13 (four boxes) | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Reading Python's `activate()` end to end (not just `_set_workflow_failure`) confirmed the job-set ordering parity too, which made the query-after-failure scenario design safe: queries apply last, so the handler answers after the body has already thrown, and the completion must still carry the response.
- The queries-last ordering meant one activation (signal + query) exercised the whole partition; no multi-activation choreography needed.

**What could improve:**
- Nothing notable; the plan's line anchor (Runner.pm:3054) had drifted slightly but the `@commands = ()` grep found the real site immediately.

**Course corrections:**
- None.

## Process Improvements

- When a spec finding says an in-code comment about a reference SDK is false, quote the verified replacement (file, method, line range, date) in both the test header and the fixed comment, so the citation cannot rot silently.

## Observations

- The partition also improves the post-terminal path: when `$workflow_terminal_emitted` suppresses a duplicate fail command, buffered handler responses now survive instead of being wiped with the buffer.
- `_task_failed_completion` is intentionally untouched: a task failure carries no commands at all (the whole completion is `failed`; the server retries the task and re-delivers queries), matching Python's activation-error path.
- Next unchecked step is R14+R15 (route `workflow_failure_exception_types` and `nondeterminism_as_workflow_fail` to live Runners); the replay harness already threads both correctly (`Test/WorkflowReplay.pm:81`), so the unit test should target the live dispatcher path at `Worker.pm:459-460` / `Worker/WorkflowDispatcher.pm:170-181`.

## Suggested Skills for Next Session

- `temporal:temporal-developer` — R14+R15 concerns workflow-vs-task failure routing and nondeterminism handling; same completion-contract ground truth as this step.
