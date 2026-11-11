# Session Summary: Keep Untyped Search Attributes Through Schedule Action Decode (F9)

**Date**: 2026-09-14
**Duration**: single step, three dispatch modes plus a two-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F9, plan.md Section 6 Step F9 (Keep Untyped Search Attributes Through Schedule Action Decode), GitHub #4 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F9, all 8 plan sub-steps)

## The Defects

A schedule action's decode kept only the search-attribute fields it could type and threw the rest away.
Describe, modify, update therefore STRIPPED any attribute the SDK did not understand, which is the exact loss sdk-python's `untyped_search_attributes` exists to prevent (`client/_schedule.py:719-729`).
Three smaller holes travelled with it: `$payload->metadata` was read without a `// {}` guard, so a hand-built payload presenting an undef where the generated class auto-vivifies an empty map died instead of skipping; `decode_value` raised on a payload it did not encode, so one unreadable attribute took a whole describe response down; and `RetryPolicy::_from_proto` passed undef scalar reads straight into the constructor, so a hand-built proto came back with no backoff coefficient at all, a value Python's proto reads can never produce.

## The Fix

`Temporalio::Schedule::Action::StartWorkflow` now carries a wire-sourced untyped residual: every indexed field the decode could not type, held as the VERBATIM `Payload` the server sent.

`_from_proto` is its only writer.
It travels on an underscore-prefixed constructor key, the same internal-channel convention `_raw_input` already uses, and an ADJUST block rejects anything that is not a blessed Payload-shaped value.
Without that guard the private key would be a back door around the spec section 7.4 ban on untyped search-attribute input, because `_to_proto` re-sends the residual verbatim and never inspects what is in it.
The accessor `untyped_search_attributes` returns a shallow copy, so adding or removing a name in the returned hashref cannot change what an update sends; the copy is hash-level only and neither side of the round trip mutates the payloads.
`_to_proto` merges the residual under the typed collection, and a name present in both keeps its TYPED value, which is the outcome of sdk-python's encode order (`client/_schedule.py:838-852` writes the untyped-not-in-typed subset first, then lets the typed set overwrite).

The residual holds payloads rather than Python's decoded `{ name => [values] }` dict.
Python decodes then re-encodes, which cannot promise byte identity, and spec section 7.4 forbids untyped values as SDK-level input, so decoding them would materialize a value shape the SDK refuses to accept back.
Holding the payload matches the raw pass-through shape `memo`, `headers`, and `_raw_input` already use in this class, and it lets an update re-emit the field byte-for-byte.

`TypedSearchAttributes::_decode_fields` is the new single decode loop, returning the typed pairs and the skipped fields together.
`_from_proto` is now a thin caller of it that keeps only the pairs, and the schedule action calls it directly because it needs both halves.
The metadata read inside it carries the `// {}` guard.

`SearchAttributeKey::_decode_value_or_skip` is the forgiving counterpart of `decode_value`, implementing Python's skip-on-shape-mismatch (`converter/_search_attributes.py:183-202`).
`decode_value` itself stays strict, because it is the documented public inverse of `encode_value`.
Python's last gate there is `isinstance(val, key.origin_value_type)`, which has no faithful Perl equivalent since a Perl scalar carries no str/int/float distinction, so the check covers what Perl can tell apart: decode failure, list-versus-scalar shape, a JSON object where a scalar belongs, and Bool, which must be a JSON boolean rather than any truthy scalar.

`RetryPolicy::_from_proto` now omits an undef read from the constructor call so the field default stands, rather than hardcoding proto3 zero values.
A wire-decoded proto already carries the proto3 defaults (probe: an unset `backoff_coefficient` reads `0` after decode and undef on a hand-built proto), so this changes only the hand-built path, and it yields the SDK defaults 2.0, 0, and 1s rather than 0, 0, and undef.

## Tests

`sdk/t/unit/schedule_action_roundtrip.t` grew by nine subtests.

- The untyped residual survives a describe, modify, update cycle.
- `_to_proto(_from_proto(x))` is byte-identical.
- Every indexed value type survives a wire-crossing round trip: Bool, Datetime, Double, Int, Keyword, KeywordList, Text.
- A payload with undef metadata is skipped rather than fatal.
- A null-encoded payload that cannot be decoded is kept in the residual rather than fatal.
- The `[1,2]` KeywordList case, which is the one that reproduced the re-encode die.
- The residual rejects a bare hashref, taking wire Payloads only.
- `RetryPolicy::_from_proto` keeps the defaults on unset fields.
- Priority decodes undef without raising.

## The Corrected Premise

The implement pass recorded a worry that a wrong-typed-but-decodable value (an Int key holding `"abc"`) still decodes as typed here, where Python's `isinstance` gate would keep it out of the typed set.
The net effect matches anyway.
Python does not DROP such a field, it moves it into its untyped residual, because `decode_search_attributes` walks every indexed field independently of what the typed pass accepted and then deletes only the names the typed pass DID accept (`client/_schedule.py:719-729`).
Perl reaches the same place from the other direction, and either way the field survives the update.

## Deviations from Plan

- Plan said: keep untyped search attributes through the schedule action decode, following sdk-python's `untyped_search_attributes`.
- Deviated: the residual holds the VERBATIM `Payload` per field (a `{ name => Payload }` map, the same raw pass-through shape `memo`/`headers`/`_raw_input` already use), not Python's decoded `{ name => [values] }` dict.
  Python decodes then re-encodes, which cannot promise byte identity; spec section 7.4 also forbids untyped values as SDK-level input, so decoding them would materialize a value shape the SDK refuses to accept back.
- Impact: an update re-emits the untyped field byte-for-byte (asserted in `schedule_action_roundtrip.t`), and `untyped_search_attributes` reads as payloads rather than values.
  A caller wanting the value decodes the payload itself.

- Plan said: `decode_value` skips on decode failure, per `converter/_search_attributes.py:183-202`.
- Deviated: the skip lives in a new `SearchAttributeKey::_decode_value_or_skip`; `decode_value` stays strict (it is the documented public inverse of `encode_value`).
  Python's last gate there is `isinstance(val, key.origin_value_type)`, which has no faithful Perl equivalent (a Perl scalar carries no str/int/float distinction), so the shape check covers decode failure, list-versus-scalar, an object where a scalar belongs, and Bool (which must be a JSON boolean).
- Impact: a wrong-typed-but-decodable value (an Int key holding `"abc"`) still decodes as typed here, where Python's `isinstance` gate would keep it out of the typed set.
  Net effect matches anyway: Python does not drop such a field, it moves it to the untyped residual, because `decode_search_attributes` walks every indexed field independently of what the typed pass accepted (`client/_schedule.py:719-729` then deletes only the names the typed pass DID accept).
  Perl reaches the same place from the other direction, and either way the field survives the update.

- Plan said: apply proto3 defaults in `RetryPolicy::_from_proto`.
- Deviated: implemented as "omit an undef read from the constructor call so the field default stands" rather than hardcoding proto3 zero values.
  A wire-decoded proto already carries the proto3 defaults (probe: unset `backoff_coefficient` reads `0` after decode, `undef` on a hand-built proto), so this only changes the hand-built path, and it yields the SDK defaults 2.0 / 0 / 1s rather than 0 / 0 / undef.
- Impact: matches the assertion the plan's RED step called for (backoff 2.0, maximum_attempts 0) and can never hand back an undef coefficient.

### Fix-loop iter 1

Validator verdict `warn`: three warns, all applied.
All three came from the Fable review of fe185c0.

- Warn 1 (`temporal.search-attributes.decode-skip`, `SearchAttributeKey.pm`).
  The KeywordList skip rule admitted any defined non-ref element, but `_normalize` rejects a non-stringish one, so a wire KeywordList payload like `[1,2]` decoded into the typed set and then killed `_to_proto` on the next update.
  Reproduced RED first: the subtest died with "KeywordList search attribute 'NumericTags' values must be strings", the exact F9 failure.
  Fixed by factoring one predicate, `_is_keyword_list_element`, that both the encode path (`_normalize`) and the wire-decode path (`_decode_value_or_skip`) call, so the two rules cannot drift apart again.
  `Scalar::Util` dropped from the file: the `blessed` check it carried was redundant with `ref`.
- Warn 2 (`docs.pod-accuracy`, `Schedule/Action.pm`).
  The POD claimed the untyped residual is never populated from constructor arguments, but `$_untyped_search_attributes` is a `:param`, so the private key was a back door around the spec section 7.4 ban on untyped input.
  Added an ADJUST guard rejecting anything that is not a blessed Payload-shaped value, and reworded the POD and the field comment: the underscore key is an internal channel for `_from_proto` (the `_raw_input` convention), and the accessor copy is hash-level only.
- Warn 3 (`docs.stale-anchor`).
  The `client/_schedule.py` untyped block is at `:719-729` in the checked-out tree, not `:711-723`.
  Corrected in `Action.pm` and in `schedule_action_roundtrip.t`.

Impact of the pass: two subtests added to `schedule_action_roundtrip.t` (the numeric-KeywordList residual and the residual's non-Payload rejection).
No public API change; the guard only closes a private key, and the decode change moves one class of value from the typed set to the residual, which re-sends it byte-for-byte either way.

### Fix-loop iter 2

Validator verdict `clean`.

## Key Actions

- Added a wire-sourced untyped residual to `Schedule::Action::StartWorkflow`, populated only by `_from_proto`, guarded by an ADJUST that accepts Payload objects only, exposed read-only, and re-emitted verbatim by `_to_proto`.
- Made typed values win over the residual on a name collision, matching sdk-python's encode order.
- Factored `TypedSearchAttributes::_decode_fields` as the one decode-or-skip loop, with the `// {}` metadata guard, and reduced `_from_proto` to a caller of it.
- Added `SearchAttributeKey::_decode_value_or_skip` implementing Python's skip-on-shape-mismatch while leaving `decode_value` strict.
- Factored `_is_keyword_list_element` so the encode validation and the decode skip share one predicate.
- Changed `RetryPolicy::_from_proto` to omit undef reads so the class defaults stand on hand-built protos.
- Grew `schedule_action_roundtrip.t` by nine subtests, including byte identity and a seven-type wire-crossing pass.
- Documented the whole rule in `Action.pm` POD under "Search attributes the SDK cannot type", cross-linked from `TypedSearchAttributes` and `SearchAttributeKey`.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F9 implement) | Executed plan.md Section 6 Step F9 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: three warns plus one info |
| Executor `mode=fix`, iter 1 | Factored the shared KeywordList predicate, added the residual's ADJUST guard, corrected the stale anchor | Applied 3, two subtests added, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean` |
| Executor `mode=finalize` | Session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- Reproducing the KeywordList warn RED before fixing it produced the exact production failure string, which confirmed the validator had found a real round-trip break rather than a theoretical one.
- Holding payloads instead of decoded values made the byte-identity assertion trivially true and sidestepped the section 7.4 conflict that decoding would have created.
- Reading Python's `decode_search_attributes` deletion order settled the "wrong-typed but decodable" worry without any code change, because both SDKs land the field in the same place by different routes.

**What could improve:**

- The encode-side KeywordList validation already existed when `_decode_value_or_skip` was written, and the skip rule was written from Python's text rather than from the sibling Perl rule ten lines away.
  Checking the encode path first would have produced the shared predicate in the implement pass instead of a fix iteration.
- The `client/_schedule.py` line anchors were copied from an earlier draft rather than re-read from the checkout, which is how a stale range reached a comment.

**Course corrections:**

- The plan allowed "residual or documented limitation"; the residual was built, since the payload-holding shape removes the reason the limitation would have been necessary.
- The plan put the skip in `decode_value`; it went into a new private method so the public inverse stays strict.

## Process Improvements

- When adding a decode-side tolerance rule, grep for the encode-side validation of the same field FIRST and make them share a predicate, rather than deriving each independently from the reference SDK.
- Re-read a reference-SDK line anchor from the actual checkout at the moment of writing the comment; an anchor carried from an earlier draft goes stale silently.
- For a round-trip fix, assert byte identity rather than field-by-field equality where the pass-through is meant to be verbatim: it catches re-encode drift that a value comparison cannot see.

## Observations

- Holding the wire `Payload` rather than a decoded value is now the third instance of the same pattern in this class (`_raw_input`, `memo`/`headers`, and now the search-attribute residual), and it is what makes byte identity assertable at all.
- The underscore-prefixed constructor key is a convention, not an access control: `:param` makes it reachable from any caller, so the ADJUST guard is what actually keeps the section 7.4 ban intact.
- JSON::PP encodes a Double search attribute of 42.0 as the bytes `42`, so a Python client reading a Perl-written whole-number Double places it in its untyped residual while Perl decodes it as typed.
  Both SDKs re-send the field unchanged, so nothing is lost, but byte identity does not hold for that value.
  Pre-existing and outside F9.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F10 rounds the shared duration pair, which is Temporal Duration and timeout semantics.
