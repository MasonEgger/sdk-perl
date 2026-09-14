# Session Summary: Prove result_type Reaches the Converter (F13)

**Date**: 2026-09-14
**Duration**: single step, three dispatch modes plus a one-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F13, plan.md Section 6 Step F13 (Prove result_type Reaches the Converter), GitHub #8 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (1), finalize (1)
- **Steps completed**: 1 of 1 (F13, all 8 plan sub-steps)

## The Gap

The Fable review of 61e9d86, which added `result_type` to `start_update` and `execute_update`, raised five warns against what that commit left behind.

No test in the repository handed a client a hint-sensitive payload converter.
Every stock converter self-describes and ignores the type hint it is given, so an implementation that stored `result_type` on the handle and then passed `undef` to `from_payloads` would pass the entire suite.
The accessor assertions and the `_update_handle` kwargs spy both stay green under that mutation, which makes them a test of plumbing rather than of behavior.

The polling branch of `result` was untested altogether.
Every existing case answered `UpdateWorkflowExecution` with a completed outcome, so `result` always took the known-outcome path and `PollWorkflowExecutionUpdate` was never reached with a hint in play.

The `WorkflowUpdateHandle` POD named only `get_update_handle` as the source of `result_type`, even after 61e9d86 added the option to two more constructors.

A self-referencing line anchor in the `start_update` comment was stale.

The `opts` hashref on `StartWorkflowUpdateInput` was undocumented: an interceptor author had no written statement of which keys it carries, nor that the hashref must be mutated in place.

## The Tests

`sdk/t/unit/start_update_result_type.t` now builds its client with a `Local::Test::HintRecorder` payload converter that pushes every `$type_hint` it is handed onto a file-scoped array and then delegates to the stock Json converter.

Three subtests assert on the recorded hints rather than on the accessor.
The start-response branch, where the update RPC returns a completed outcome and `result` decodes it without polling.
`execute_update`, whose handle never reaches the caller but whose decode must still carry the hint.
The polling branch, where the update RPC returns `ACCEPTED` with no outcome, `result` reaches `PollWorkflowExecutionUpdate`, and the polled outcome is decoded with the hint.

The RED proof is recorded in a comment above the recorder.
With `WorkflowUpdateHandle::_decode_all_payloads` passing `undef` instead of `[$result_type]`, exactly the three new hint assertions fail with `GOT <UNDEF> CHECK My::ResultType`, one per subtest, while all six pre-existing assertions in the file stay green.
That is precisely the false pass a hint-blind converter cannot catch.

The polling subtest also pins the request shape at finalize: the poll's `update_ref->update_id` matches the handle's own `update_id`, and the request carries the client identity `id-i8@host`.
That was the validator's one info finding, applied here because both assertions land in a file already in the diff.

## No Production Change Was Needed

`WorkflowUpdateHandle::_decode_all_payloads` already passed `[$result_type]` on both branches of `result`.
Sub-step 3 (GREEN, "fix anything exposed") exposed nothing, and sub-steps 4 and 5 were planned as no-ops.
The only production edits in this step are a comment and POD, so F13 is a test-and-docs step that converts an untested claim into a held one.

## The Docs

The `WorkflowUpdateHandle` DESCRIPTION now names all three constructors that set `result_type`: `start_update`, `execute_update` (which builds one internally and returns `->result` from it), and `get_update_handle` (no RPC).
The `result_type` accessor POD states that the hint is applied on both branches of `result`, that only a custom payload converter observes it, and that `start_update_result_type.t` is what pins it.
The `_new` synopsis names all three rather than two.

`Temporalio::Client::Interceptor` gained an INPUT CLASSES section documenting the `StartWorkflowUpdate` input: the `opts` keys (`wait_for_stage`, `update_id`, `result_type`) with their defaults and their failure modes, and the in-place mutation rule.
Python keeps these as named fields on `StartWorkflowUpdateInput`; here they share one hashref, so an interceptor writes `$input->get('opts')->{result_type} = ...` and `$input->set('opts', ...)` throws, since only `args` and `headers` are writable (spec section 27.1).

The stale `:584-586` anchor in the `start_update` comment is replaced with a method-name reference, and the comment now records the full Python path: the option on the interceptor input as `ret_type`, read back to build the handle.

## Python Anchors

The plan's shorthand cited `client.py` and `_impl.py`.
The sdk-python client is a package, not a single module, so the real paths are `temporalio/client/_workflow.py` (`execute_update` at :787, `start_update` at :903, `_start_update` at :951 and :971, the handle's `result_type` field at :1855 and :1867, the decode at :1929-1932), `temporalio/client/_impl.py:766` (the handle built with `result_type=input.ret_type`), and `temporalio/client/_interceptor.py` (`StartWorkflowUpdateInput` fields at :316, :319, :321).
Every cited line number matched; only the file path in the plan's shorthand was off.

## Deviations from Plan

- Plan said: "Verify the Python contract (client.py:787, :903, :971; _impl.py:766; :1929-1932)".
- Deviated: the Python client is a package, not a single module, so the real paths are
  `temporalio/client/_workflow.py` (:787 execute_update, :903 start_update, :951/:971 _start_update,
  :1855/:1867 the handle's result_type field, :1929-1932 the decode), `temporalio/client/_impl.py:766`
  (handle built with `result_type=input.ret_type`), and `temporalio/client/_interceptor.py:316/:319/:321`
  (StartWorkflowUpdateInput update_id / wait_for_stage / ret_type).
  Every cited line number matched those files exactly; only the file path in the plan's shorthand was off.
- Impact: none. Citations in the diff name the package paths.

- Plan said (dispatch elaboration): reuse or mirror a recording converter already exposed under sdk/t/lib.
- Deviated: there is none. `t/lib/CodecBoundary.pm` only CALLS `$PC->from_payload` as a decode helper;
  no fixture records hints.
  Mirrored the in-file custom-converter pattern from `t/unit/converter_payload.t`
  (`class Local::Test::CustomConverter :isa(Temporalio::Converter::Payload)`) instead, as a single
  attributed class in the test file with no fields (file-scoped lexicals for the inner Json converter
  and the recorded hints, avoiding the `field ... = <default>` adjacent to a signatured method parser
  hazard documented in Client/Interceptor.pm).
- Impact: the recorder lives in the one test that needs it rather than in t/lib.
  If a second test ever needs hint recording, promote it then.

- Plan said: sub-step 3 GREEN, "fix anything exposed".
- Deviated: nothing was exposed. `WorkflowUpdateHandle::_decode_all_payloads` already passed
  `[$result_type]` on both branches of `result`, and the RED proof (temporarily passing undef) failed
  exactly the three new hint assertions while every pre-existing assertion stayed green.
  The only production edits in this step are the sub-step 6 comment and the sub-step 7 POD.
- Impact: no behavior change; the step is a test-and-docs step.

- Plan said: sub-step 6, "replace the stale anchors in WorkflowHandle.pm comments with method names".
- Deviated: only ONE self-referencing anchor in WorkflowHandle.pm was stale (`:584-586` in the
  start_update comment; get_update_handle passes result_type at 593).
  Left `(:616-630)` in the fetch_history comment alone because it is still accurate for
  fetch_history_events.
  Also replaced a stale anchor the plan did not name, in the test file's own spy comment
  (`WorkflowHandle.pm :595 _update_handle`, now 602), since the house rule requires method-name or
  FINAL anchors on added lines.
- Impact: one extra comment line touched outside the named file.

### Validation, iter 1

Validator verdict `clean`, with one optional info finding.
The polling subtest proved the RPC was reached but not what the request carried, so the poll's `update_ref->update_id` and `identity` are now asserted.
Applied during finalize because both assertions land in a file already in the diff.

Two cosmetic fixes were made at finalize alongside it: an unbalanced closing paren in the new `start_update` comment, and a ragged POD line wrap in the new Interceptor section.

## Key Actions

- Added `Local::Test::HintRecorder`, an in-file payload converter recording every decode hint, and built the test client's data converter around it.
- Asserted the recorded hint on all three paths: the start-response branch, `execute_update`, and the polling branch.
- Recorded the RED proof: passing `undef` instead of `[$result_type]` fails exactly the three hint assertions while the six older ones stay green.
- Added a polling subtest that answers `UpdateWorkflowExecution` with `ACCEPTED` and no outcome, forcing `result` through `PollWorkflowExecutionUpdate`.
- Pinned the poll request shape (`update_ref->update_id`, `identity`) at finalize per the validator's info finding.
- Rewrote the `WorkflowUpdateHandle` POD to name all three constructors and to state that the hint applies on both branches of `result`.
- Added an INPUT CLASSES section to `Temporalio::Client::Interceptor` documenting the `StartWorkflowUpdate` `opts` keys and the in-place mutation rule.
- Replaced the stale `:584-586` anchor in the `start_update` comment with a method name, plus a stale anchor in the test's own spy comment.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F13 implement) | Executed plan.md Section 6 Step F13 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `clean`, one optional info |
| Executor `mode=finalize` | Applied the info, session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Proving RED by mutating the real production line (pass `undef` instead of `[$result_type]`) rather than by deleting the feature is what showed the six older assertions to be hint-blind.
  The mutation is the exact wrong implementation the review predicted.
- Checking `t/lib` for an existing recorder before writing one cost little and produced a defensible reason for keeping the new class in-file.
- The validator's info was cheap to apply because it added assertions to a subtest already being written.

**What could improve:**

- The plan's Python anchors were line-accurate but path-wrong, which cost a search.
  A path that has already been verified once in a prior step should be copied forward verbatim.
- Two cosmetic defects (an unbalanced paren, a ragged wrap) survived the implement pass and were caught only by reading the diff at finalize.

**Course corrections:**

- Corrected the plan's `client.py` shorthand to the package paths and cited those in the diff.
- Kept the recorder in the test file rather than promoting it to `t/lib` on first use.

## Process Improvements

- A type hint is only proven consumed when the test's converter is sensitive to it.
  Asserting the accessor, or spying on the constructor kwargs, proves storage and nothing more.
- When a step is predicted to need no production change, spend the budget on the untested branch instead.
  Here the polling path was the real gap.
- Read the full `git diff HEAD` at finalize even after a clean validator verdict; punctuation and wrapping defects slip past a semantic review.

## Observations

- F13 is the second follow-up in this section where the production code was already correct and the test was the defect.
  F12 had a working shield with nothing holding it in place; here the hint reached the converter with nothing proving it.
- The self-describing stock converters are what make this class of false pass possible: they accept a hint and discard it, so nothing downstream can distinguish a real hint from `undef`.
- Documenting the `opts` hashref exposed a genuine asymmetry with Python, which keeps the same three values as named fields on its input class.
  The mutation rule is a Perl-only constraint and had never been written down.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F14 bounds workflow priority to what the wire carries, which is a Temporal proto field-range question.
