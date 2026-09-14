# Session Summary: Make Fork-Pool Frame Pairing Token-Exact (F6)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a two-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F6, plan.md Section 6 Step F6 (Make Fork-Pool Frame Pairing Token-Exact), GitHub #7 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F6, all 8 plan sub-steps)

## The Four Warns

All four came from the Fable review of 879c5fb, the I7 commit that first wired the pooled heartbeat chain and the pooled `cancellation_details` holder.
Each is a frame on the fork pool's control socket being matched to the wrong invocation, or a frame being acted on when the matching one never arrived.

1. `_child_drain_control` keyed the cancelled flag by `$msg->{token}` but wrote `$child->{holder}{details}` unconditionally.
   A cancel frame can outlive the invocation it names: the parent still holds token A inflight after the child's body stopped polling and A's `end` frame went out, which is the normal shape at worker shutdown, where core cancels every running activity.
   That frame is drained by the NEXT invocation on the same child, which then reported a `cancellation_details` it never earned with `is_cancelled` false.
2. `Context::_record_heartbeat` sent the raw-details frame BEFORE calling `encode_heartbeat_bytes`.
   A heartbeat whose encode dies therefore left an orphan `hbd` parked on the connection, which paired with a LATER heartbeat's `hb`, and the parent re-encoded the earlier heartbeat's args in place of the later one's.
3. The parent's chain-failure fallback caught the throw, warned, and then relayed the child's pre-chain bytes, recording a value the interceptor chain had refused to pass on.
   The async path records nothing in the same situation.
   The comment justified the relay with a Python try/except at `_activity.py:838-844` that does not exist.
4. The teardown-race test armed its hold AFTER `start` had already registered `%token_conn`, so the rejected parent-side `%token_conn` guard would have passed it.
   `control_connected` was proven only by the I7 summary's stress loop, not by anything in the suite.

## The Fixes

The holder write is now token-guarded.
`_child_dispatch` binds `$child->{holder_token}` next to the holder it creates, and `_child_drain_control` writes the decoded details only when the frame's token matches.
This is the same identification the async dispatcher gets for free, because Python looks the holder up by task token (`worker/_activity.py:221`, over `_running_activities`) and each running activity owns its own holder (`:741`, handed to the sync worker's context at `:938` and `:968`).

`Context::_record_heartbeat` now encodes first and relays the raw details second, so a heartbeat that fails to encode sends neither frame and nothing is ever parked without its own bytes following immediately.
The plan's alternative, tagging both frames with a per-invocation sequence number and pairing only on a match, was rejected and the rejection documented in the code.
The child is synchronous, so it cannot have two heartbeats in flight at once; once the orphan case is gone, "the details immediately before these bytes" already identifies the pair exactly, and a sequence tag buys nothing for the extra frame field.
The reverse case stays benign on purpose: an `hb` that arrives with no parked details (its `hbd` was lost to a Storable freeze failure, which is best-effort) still relays the child's bytes directly.

Chain failure now warns and drops instead of relaying.
A chain that threw delegated nothing, so no heartbeat was recorded, which matches the async path where the interceptor's `die` propagates out of the body's own `heartbeat()` call.
The Python citation was corrected to the code that actually exists: a thread pool re-raises the chain failure into the body through `.result(10)` (`worker/_activity.py:851-853`, over the `outbound.heartbeat` installed on the context at `:813-818`), and a process pool's parent-side heartbeater logs the exception and ends its poll loop (`worker/_activity.py:1114-1116`).

The race test got a new test-only seam, `_hold_control_drain_at_accept`, which holds a newly accepted connection before its first read-ready so not even `start` is drained and `%token_conn` stays empty for the token the child is running.
That is the reply-before-`start` ordering the child's own `control_connected` report exists for, and the one a parent-side `%token_conn` guard could not survive.
It was mutation-checked out of band against the rejected guard: with `invoke()`'s `unless $out->{control_connected}` temporarily replaced by `unless defined $token_conn{$token}`, the new hold-at-accept subtest fails while the older hold-after-start subtest still passes, which is exactly the discrimination the old test could not make.

The R84 parity subtest now calls `notify_shutdown` on BOTH sides before the cancel and compares `is_worker_shutdown` across them.
It also pins the async side's own values first (`reason` is `WORKER_SHUTDOWN`, `is_worker_shutdown` is true), because before F6 the async side never called `notify_shutdown` and the cross-path comparison would have passed on a pair of undefs.

## RED Confirmation

Three of the five new cases fail on HEAD, as the plan predicted.
The late-cancel case reports A's reason on B with `is_cancelled` false.
The pairing case has the parent's chain observe two heartbeats, the first being heartbeat 1's parked details paired with heartbeat 2's bytes.
The chain-dies case has the heartbeat relayed rather than dropped.
The hold-at-accept variant and the `is_worker_shutdown` parity assertion are coverage the old suite lacked rather than live defects, so they pass once written.

## Deviations from Plan

- Plan said: sub-step 1, "a body whose first heartbeat detail fails encoding and whose second succeeds must relay the SECOND detail's args to the chain, never the first's".
- Deviated: the fixture records THREE heartbeats, not two.
- Impact: the stale-pairing bug only manifests when the second heartbeat's own `hbd` frame is missing (the plan's own parenthetical: the unfreezable fixture shape sends `hb` with no `hbd`).
  With only those two, the post-fix chain observes nothing at all, so the subtest could only assert an absence.
  ActDef::PoolHeartbeatPairing therefore adds a third heartbeat whose detail both freezes and converts, giving the assertion a positive form: post-fix the chain observes exactly one heartbeat carrying its own args; pre-fix it observes two, the first being heartbeat 1's parked details paired with heartbeat 2's bytes.

- Plan said: nothing about a new t/lib fixture; sub-step 1 says "extend" the two test files.
- Deviated: added sdk/t/lib/ActDef/PoolHeartbeatPairing.pm (one attributed class, per the house rule).
- Impact: the pairing body needs three specific detail shapes (freezes but does not convert, converts but does not freeze, survives both) and a pooled sync activity body has to be a registry-resolvable definition in the child.
  Following the PoolHeartbeatIntercepted/PoolHeartbeatUnfreezable precedent in the same file keeps the shapes named and documented instead of inlined.

- Plan said: sub-step 7, "Pool.pm POD on frame pairing guarantees and the chain-failure rule".
- Deviated: also amended Context.pm's `heartbeat_details_recorder` POD entry.
- Impact: the encode-before-relay ordering is enforced in Context::_record_heartbeat, so the constructor entry that documents the recorder is where a caller wiring one would look for the contract; it links to the new Pool.pm section rather than restating it.

- Plan said: nothing about mutation-checking the hold-at-accept variant.
- Deviated: verified it out of band by temporarily replacing invoke()'s `unless $out->{control_connected}` with the rejected `unless defined $token_conn{$token}` guard.
- Impact: subtest 7 (hold-at-accept) failed under the rejected guard while subtest 5 (hold-after-start) still passed, which is exactly the discrimination the plan says the old test could not make.
  Pool.pm was restored from a scratchpad copy before the suite runs.

### Fix-loop iter 1

The validator returned 3 warn, 0 block, 0 info, all `docs.stale-invariant-comment`, and all three fixes were comment text only.

- `Context.pm` `heartbeat_details_recorder` field comment: "BEFORE payload conversion" became "AFTER that heartbeat's payload conversion has succeeded (step F6)".
- `Pool.pm` `_child_dispatch` hbd wiring comment: raw details are relayed AFTER `Context::_record_heartbeat` encodes and BEFORE the bytes-based recorder sends.
- `Pool.pm` `_hold_control_drain` method comment: "the NEXT connection's start frame" became "EVERY start frame drained while it is armed", matching the already-correct field comment.
- A sweep with `grep -n 'BEFORE payload\|before.*encod\|NEXT connection\|next .*start'` over `sdk/lib/Temporalio/Activity/*.pm` left three hits (Context.pm:67, Pool.pm:103, Pool.pm:283), all reading "before the pre-encoded bytes reach the real heartbeat_relay".
  That is still true post-F6, because the parent's chain runs before the bytes hit the FFI relay, so all three were left alone.
- Verified comment-only by reconstructing the pre-fix files from the inverted replacements and diffing; no non-comment line appears in the pass diff, and `perl -c` is clean on both files.

### Fix-loop iter 2

The validator returned clean with zero findings.

## Key Actions

- Guarded the child's cancellation-details holder write by task token, with `holder_token` bound where the holder is created.
- Reordered `Context::_record_heartbeat` to encode before relaying, and documented why the sequence-tag alternative was rejected.
- Changed chain failure from warn-and-relay to warn-and-drop, matching the async path, and corrected the Python citation to code that exists.
- Added `_hold_control_drain_at_accept`, the seam that reproduces reply-before-`start`, and mutation-checked it against the rejected `%token_conn` guard.
- Extended the R84 parity subtest to call `notify_shutdown` on both paths and to pin the async side's own values before comparing.
- Added `sdk/t/lib/ActDef/PoolHeartbeatPairing.pm`, a three-heartbeat body whose detail shapes make the pairing assertion positive rather than an absence.
- Documented both guarantees in Pool.pm POD under "Frame pairing guarantees (step F6)" and the drop rule under its own heading.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F6 implement) | Executed plan.md Section 6 Step F6 sub-steps 1-8 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: three stale invariant comments |
| Executor `mode=fix`, iter 1 | Rewrote the three comments to match the new ordering and the non-one-shot hold | Applied 3, deferred 0, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean`, zero findings |
| Executor `mode=finalize` | Session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- The fixture's three detail shapes (freezes but does not convert, converts but does not freeze, survives both) turn a stale-pairing bug that would otherwise only show as an absence into a positive assertion with a distinct pre-fix and post-fix count.
- Mutation-checking the new race seam against the specific guard the I7 review rejected proves the test discriminates, rather than merely passing.
- Pinning the async side's own values before a cross-path comparison caught a parity subtest that would have compared two undefs.

**What could improve:**

- The four warns were all ordering and identification defects on the same channel, found by review rather than by the suite.
  A channel that carries paired frames deserves a test that asserts the pairing directly, at the time the pairing is introduced.

**Course corrections:**

- The plan offered a sequence tag as an equal alternative to reordering the two calls.
  Took the reordering and wrote the rejection into the code, because a synchronous child cannot have two heartbeats in flight and the tag would be dead weight in every frame.

## Process Improvements

- When a code comment cites a specific file and line range in a reference SDK, check the range before trusting the behavior it claims.
  The relay-on-chain-failure fallback was justified by a try/except that is not in `_activity.py` at all, and the real code does the opposite.
- A regression test for an ordering bug has to be able to fail under the rejected fix as well as the absent one.
  Arming a hold after the state it is meant to exclude has been registered tests nothing about that state.

## Observations

- A frame outliving the invocation it names is not exotic: worker shutdown cancels every running activity, so the late-cancel window opens on the ordinary shutdown path rather than under load.
- Containment and relaying were conflated in the I7 code.
  Keeping a throw out of the read-ready callback is necessary; recording the value the chain refused to pass on is a separate decision that happened to ride along with it.
- The `hbd`/`hb` orphan and the stale cancel are the same defect in two places: state parked on a connection, then consumed by whichever invocation reads next.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F7 honors dynamic update validators on every path, which is workflow update semantics.
