# Session Summary: Honor Dynamic Update Validators on Every Path (F7)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a two-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F7, plan.md Section 6 Step F7 (Honor Dynamic Update Validators on Every Path), GitHub #9 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F7, all 8 plan sub-steps)

## The Warns

Both came from the Fable review of 8e5bdaf, the I9 commit that first added a `validator` option to `set_dynamic_update_handler`.

1. An `:UpdateValidator` naming a `:Update(dynamic=1)` method was registered but never consulted.
   A dynamic handler has no update name, so the attribute's argument can only be the guarded method's own name, and nothing in `_handlers` mapped that key onto the dynamic definition.
   Only the runtime spelling (`set_dynamic_update_handler` with a `validator`) reached the dispatch path, so the two registrations disagreed.
2. `_apply_do_update` called the resolved validator directly instead of through the workflow inbound interceptor chain.
   An interceptor overriding `validate_update` observed nothing, even though the chain had a slot for it and `handle_update` already flowed through it.

## The Fixes

`Definition::_register_handler` now records `$_DEFS{$pkg}{dynamic_methods}{$dyn_kind}`, the method name behind each dynamic slot, and `_workflow_defs` exposes a `dynamic_methods` bucket.
`Runner::_handlers` reads it: when a validator's key equals the dynamic `:Update` method's name, the entry is promoted into `$h->{dynamic}{update_validator}`, the same slot the runtime path writes.
The entry is COPIED, not moved, so a separately declared `:Update` whose name happens to equal that method name keeps its own validator.
That gives `_resolve_update_validator` one place to read regardless of how the validator was registered, and it is the state sdk-python reaches through `@workflow.update(dynamic=True)` plus `@fn.validator`, which calls `set_validator` on the dynamic `_UpdateDefinition` (`workflow/_handlers.py:382`).

`_run_update_validator` now takes the update id, name, and dynamic flag, builds an `Input::HandleUpdate` with a `_root` coderef, and runs `$workflow_inbound->validate_update($input)` inside the read-only depth.
`_RootWorkflowInbound` gained the matching chain root, one line next to `handle_signal` and `handle_query`.
The root just calls `_root` because the caller has already resolved WHICH validator applies, so the no-fallback rule lives in `_resolve_update_validator` alone rather than being re-derived in the chain the way Python re-derives it.
This is the analog of sdk-python's `self._inbound.handle_update_validator(handler_input)` inside `with self._as_read_only(in_query_or_validator=True)` (`_workflow_instance.py:650`).

A validator that returns a Future which is not ready is now rejected with an application failure of type `AsyncUpdateValidator` whose message names the fix.
The abandoned Future is cancelled so nothing keeps waiting on a result no one will read.
A rejection was chosen over acceptance and over a task failure: it is deterministic across replays, it tells the caller what to change, accepting would ship an unvalidated update, and a task failure would wedge the workflow task in a retry loop.
sdk-python has the looser behavior here: it calls the validator as `handler(*input.args)` with no await, so an `async def` validator hands back a merely truthy coroutine and the update is accepted unvalidated.

## Two Corrections to the Spec's Premises

The spec and the plan said a pending-Future validator is "silently accepted" today.
It is not.
`Future->failure` croaks on a pending Future, so the old code died inside `_apply_do_update` and the update produced no `UpdateResponse` at all.
That also forced a readiness check into the leak backstop (`!($future->is_ready && $future->failure)`), which the plan did not call out.

The spec also read Python's `self._updates.get(name) or self._updates.get(None)` as a validator fallback.
It is not a fallback for validators: a named definition that exists but has no validator short-circuits the `or`, so the dynamic definition is never reached, which is exactly what the comment at `_workflow_instance.py:2938-2941` says is intended.
The Perl `($name, $is_dynamic)` pairing is equivalent, and a subtest now pins it: a named update with no validator of its own is accepted unvalidated while a dynamic validator is installed, and the dynamic validator's rejection message never appears.

## Precedence Between the Two Spellings

Both spellings write `$h->{dynamic}{update_validator}`, so a runtime `set_dynamic_update_handler` call replaces an attribute-declared dynamic validator wholesale, including clearing it when the call omits `validator`.
That matches Python, where the runtime definition replaces the decorated one.
It is now stated in `set_dynamic_update_handler`'s POD and pinned by a mixed-spelling subtest.

## Tests

`sdk/t/replay/dynamic_update_validator.t` went from 3 subtests to 13, nine added during implement and one during the fix loop.
The new cases cover the attribute validator on a dynamic `:Update` rejecting and admitting, the no-fallback rule, a named attribute validator's own message and type, runtime install and uninstall symmetry, a runtime dynamic install replacing the attribute-declared one, an inbound interceptor observing `validate_update` on both the named and the dynamic path, a rejecting validator stopping the chain before `handle_update`, and the pending-Future rejection.
Three new fixtures carry the shapes: `WfDef::AttrDynUpdateValidator` (attribute-declared dynamic validator plus a runtime-install signal), `WfDef::DynUpdateValidatorReinstall` (runtime install and uninstall), and `WfDef::AsyncUpdateValidator` (a validator that returns a pending Future).

## Args Isolation

The validator and the handler each receive a separate shallow copy of the decoded args, so an interceptor or validator that rewrites the array inside `validate_update` cannot reach the handler.
An in-place mutation of a reference-typed element still can, because sdk-python re-decodes the payloads for the handler after validation (`_workflow_instance.py:651-658`) and we do not.
That difference is pre-existing, documented at the call site, and left for a follow-up.

## Deviations from Plan

- Plan said: the pending-Future validator case is "silently accepted" today (spec F7 and the plan NOTE at ~3710-3714).
- Deviated: on HEAD it is not silently accepted.
  `Future->failure` croaks on a pending Future ("is not yet complete and does not provide ->await"), so the old `_run_update_validator` died inside `_apply_do_update` and the update produced no UpdateResponse at all.
  The RED subtest failed on the command count rather than on an unexpected acceptance.
- Impact: the guard had to come with a readiness check in the leak backstop too (`!($future->is_ready && $future->failure)`), which the plan did not call out.
  The chosen outcome is the plan's permitted alternative: a rejection with failure type `AsyncUpdateValidator`, not a task failure.

- Plan said: "_handlers maps an attribute validator whose name matches the dynamic :Update method into dynamic => { update_validator => ... }".
- Deviated: the registry had no way to answer "which method is behind the dynamic update slot", so `Definition::_register_handler` now records `$_DEFS{$pkg}{dynamic_methods}{$dyn_kind}` and `_workflow_defs` exposes a `dynamic_methods` bucket.
  The Runner match reads that.
- Impact: one extra bucket on the public-ish `_workflow_defs` shape, noted in Definition.pm's POD.
  The validator entry is COPIED into the dynamic slot, not moved, so a separately declared `:Update` whose NAME equals the dynamic method name keeps its own validator.

### Fix-loop iter 1

The validator returned 1 warn and 1 info, 0 block.

- Warn `plan.F7.step1.rejection-message-and-type`: the pending-Future subtest pinned only the rejection prose, so renaming the failure type in Runner.pm left the suite green while breaking the POD contract.
  Added an assertion on `application_failure_info->type eq 'AsyncUpdateValidator'` plus a `qr/'slow'/` pin on the message.
  Mutation-checked: renaming the type to `MUTATED_AsyncUpdateValidator` in Runner.pm:3899 failed exactly the new type assertion (both message regexes still passed, which is the point), then the string was restored and the file went green again.
- Info `plan.F7.step1.install-uninstall-symmetry`: applied BOTH halves, since the POD sentence alone does not pin the precedence.
  Added a sentence to `set_dynamic_update_handler`'s POD saying a runtime install replaces an attribute-declared dynamic validator too, and added the mixed-case subtest "a runtime dynamic install replaces the attribute dynamic validator".
  The subtest needed a new writable entry point on the fixture, so `WfDef::AttrDynUpdateValidator` gained an `install_runtime_dynamic` signal that calls `set_dynamic_update_handler` with a handler and no validator; its `runtime:` result prefix proves the handler was replaced as well as the validator.
  Both spellings write `$h->{dynamic}{update_validator}`, so `workflow_set_update_handler` (Runner.pm:3605-3610) deletes the attribute-promoted entry on a validator-less dynamic install.
- Orchestrator ask (no finding): documented the validator/handler args isolation at the `_run_update_validator` call site, citing `_workflow_instance.py:651-658`.
  Comment only, no code change.
- Suites after the fixes: `prove -lj4 t` 212 files / 946 tests green (the replay file went 12 to 13 subtests); `prove -lj4 xt` 8 files / 474 tests green, POD coverage and syntax included.

### Fix-loop iter 2

The validator returned clean, with one info finding on the args isolation and a request to reword the call-site comment.
The comment now says sdk-python goes further by re-decoding the payloads for the handler, where Perl hands each phase a shallow copy, so an in-place mutation of a reference-typed argument can still cross the boundary.

## Key Actions

- Added a `dynamic_methods` registry to `Definition.pm` so an `:UpdateValidator` can name the dynamic `:Update` method, and promoted a matching validator into the dynamic slot in `Runner::_handlers`, copied rather than moved.
- Routed `_run_update_validator` through `$workflow_inbound->validate_update` with a real `Input::HandleUpdate` and a `_root` coderef, under the read-only depth.
- Added the `validate_update` chain root to `_RootWorkflowInbound` and documented the method's contract in `Interceptor.pm`'s POD.
- Rejected a validator that returns a pending Future with failure type `AsyncUpdateValidator`, and cancelled the abandoned Future.
- Fixed the leak backstop to check readiness before calling `->failure`, which croaks on a pending Future.
- Corrected two of the spec's premises in code comments and POD: the pending-Future case was a die, not a silent accept, and Python's `get(name) or get(None)` is not a validator fallback.
- Documented and pinned the precedence rule: a runtime dynamic install replaces an attribute-declared dynamic validator wholesale.
- Grew `sdk/t/replay/dynamic_update_validator.t` from 3 subtests to 13 and added three `WfDef` fixtures.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F7 implement) | Executed plan.md Section 6 Step F7 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: an unpinned failure type, plus a precedence info |
| Executor `mode=fix`, iter 1 | Pinned the type with a mutation check, applied both halves of the precedence info | Applied 2, deferred 0, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean`, one info on args isolation |
| Executor `mode=finalize` | Comment reword, session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Checking the spec's premise against HEAD before writing the fix caught two wrong claims, one of which changed the fix (the readiness check in the leak backstop would not have been written otherwise).
- Reading `_workflow_instance.py:2938-2941` in full, comment included, settled the no-fallback question in the reference SDK's own words rather than by inference from the `or` expression.
- Mutation-checking the failure-type assertion proved the new pin discriminates, rather than merely passing alongside the message regexes.

**What could improve:**

- Two registration spellings for the same thing (attribute and runtime) went a whole feature commit without a test that exercised them against each other.
  A mixed-spelling case belongs in the suite the moment the second spelling lands.

**Course corrections:**

- The plan allowed either a task failure or a rejection for the async-validator case.
  Took the rejection, because a task failure on a deterministic coding error retries forever while a rejection is decided identically on every replay.

## Process Improvements

- When a spec requirement asserts current behavior ("silently accepted today"), reproduce it before designing around it.
  The RED subtest here failed for a different reason than the spec predicted, and the real failure mode needed a second guard.
- A validator or handler slot that can be filled two ways needs a test for the precedence between them, not just one test per way.

## Observations

- `Future->failure` is only legal on a ready Future; calling it on a pending one croaks from `->await`.
  That turns "wrap the callback and read `->failure`" into a die at the call site whenever the callback was async, which is how the pending-Future case became an empty response rather than an accept.
- Python's looser handling of an `async def` validator (an un-awaited coroutine is truthy, so the update is accepted unvalidated) is the more dangerous failure of the two, because nothing surfaces it.
- Resolving which validator applies in one helper and letting the chain root call `_root` keeps the no-fallback rule in a single place, where Python re-derives it inside the inbound impl.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F8 settles handlers silently during eviction, which is workflow eviction and handler-completion semantics.
