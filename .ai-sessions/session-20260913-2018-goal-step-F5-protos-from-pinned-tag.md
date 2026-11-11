# Session Summary: Re-vendor the Cloud, Test, and Health Protos From the Pinned Tag (F5)

**Date**: 2026-09-13
**Duration**: single step, three dispatch modes plus a two-iteration validation loop
**Conversation Turns**: not tracked (subagent dispatch context)
**Estimated Cost**: not tracked
**Model**: claude-opus (executor), claude-fable-5-1 (validator and orchestrator)

## Goal Context

- **Condition**: spec.md F5, plan.md Section 6 Step F5 (Re-vendor Cloud, Test, and Health Protos From the Pinned Tag), GitHub #12 follow-up.
- **Mode**: step
- **Outcome**: converged
- **Turn count**: not tracked
- **Subagent dispatches**: implement (1), validate (2), fix (1), finalize (1)
- **Steps completed**: 1 of 1 (F5, all 5 plan sub-steps)

## The Provenance Error

The I12 commit that first vendored the cloud, testservice, and health protos claimed the pinned sdk-rust tag predates those trees entirely, and vendored them from the `../sdk-rust` checkout's HEAD instead.
The claim is wrong.
`v0.4.0` holds all four trees, under `crates/common/protos/`.
The protos crate MOVED after the tag, to `crates/protos/protos/`, so the check that produced the claim looked at the post-tag path while standing on the tag, found nothing there, and concluded the protos did not exist yet.
The right question to ask is of the tag itself, not of a directory guess: `git -C ../sdk-rust ls-tree -r --name-only v0.4.0 | grep <basename>`.

The consequence was real but small.
Of the 19 files vendored under that bad provenance, 18 were byte-identical to the tag anyway, because upstream had not touched them.
The exception is `temporal/api/cloud/connectivityrule/v1/message.proto`, where a post-tag upstream added `bool enable_stable_ips = 1` to `PublicConnectivityRule`.
The installed 0.4.0 c-bridge decodes cloud responses with its own prost types, which do not know that field, so it is dropped on the way through and a Perl caller would read a value that never survives the round trip.

## The Re-Vendor

All 19 files were re-copied from `v0.4.0:crates/common/protos/`, with the upstream prefix mappings the tag layout requires.
`temporal/api/cloud/...` lives at `api_cloud_upstream/temporal/api/cloud/...`, `temporal/api/testservice/...` at `testsrv_upstream/temporal/api/testservice/...`, and `grpc/health/v1/` and `protoc-gen-openapiv2/options/` sit at the protos root under their own names.
18 files were already identical, so `connectivityrule/v1/message.proto` is the only vendored file in the diff: `PublicConnectivityRule` is now the tag's empty message.

The pre-existing `api_upstream`, `local`, and `google/rpc` files match the tag too, 66 of 67.
The exception is `workflow_activation_fq.proto`, a generated variant that is in no git tree and that `Temporalio::Core::Proto` excludes from parsing anyway.
So the "the vendored tree tracks checkout HEAD" rule recorded under I12 was never true of anything except the one file the bad provenance produced.

## The Service-Code Pins

`%RPC_SERVICE` in `Client/Connection.pm` was a file lexical that no test read, which made the "discriminator 3/4/5" phrases in `raw_service_extra.t` decoration rather than assertions.
Two signature-less class methods now expose it: `_service_code($name)` returns the integer or undef, and `_service_names` returns the sorted key list for the error message.
`rpc_call` reads both, so the pins cover the dispatch path rather than a copy of the table.
They are signature-less on purpose, because a signatured sub ahead of this class's `field ... :param` declarations trips the 5.38.2 parser trap in `lessons.md`.

The new assertions pin workflow through health as 1 through 5 against lines 8 to 14 of `temporal-sdk-core-c-bridge.h` at the tag, where only the first arm carries a literal and the rest are positional.
A second subtest pins the response class of the cloud `GetUsers` call in both spellings, the resolved class and the literal generated package name, so the descriptor output type is proven to win over `rpc_call`'s `s/Request$/Response/` fallback.
A third subtest drives `rpc_call` with an unknown service key and pins the `Temporalio::Exception::Argument` throw plus its anchored message text.
A fourth pins the vendored vintage directly: `PublicConnectivityRule` has no fields at the tag, with `PrivateConnectivityRule`'s three fields as the control against an empty-stub false pass.

## The Lazy-Load Probe

The plan allowed deferring the cloud and testservice roots to first use if a probe showed it was safe.
It is not, for two independent reasons, both confirmed this session.
`Protobuf::Schema::resolve` latches on `$resolved` with no reset (`Schema.pm:93`), so a file added by `add_file` after the first resolve is indexed but never type-resolved or feature-resolved.
A second schema is not an isolation either, because `temporal/api/cloud/nexus/v1/message.proto` (line 12), which `cloudservice/v1/request_response.proto` pulls in at its line 17, imports `temporal/api/common/v1/message.proto`, so generating it would reinstall the shared `Temporalio::Proto::Api::Common::V1::*` classes over the live ones that back every payload on the hot path.

The measured cost is documented in `Core/Proto.pm` POD instead, which was the plan's stated fallback.
Warm cache, two runs each: 67 files, 1.73s and 1.85s, 40 MB peak RSS without the cloud, testservice, and health roots; 87 files, 2.26s and 2.52s, 45 MB with them.
A client that never touches a raw cloud or test handle therefore pays about 0.6 seconds and 5 MB at startup.

## The Vendoring-Script Rewrite

`sdk/xt/author/vendor-protos.pl` was not in the plan's artifact list, but it had to change.
It hardcoded the post-tag source root `crates/protos/protos`, the exact path whose absence at `v0.4.0` produced the false provenance call, and it copied only `api_upstream`, `local`, and `google/rpc`.
Running it, which `Core/Proto.pm`'s own die message tells you to do, would have wiped `share/proto`, deleted all 19 re-vendored files, and re-vendored the rest from whatever the checkout was sitting on.
Without the fix the F5 end state, every vendored file byte-identical to the tag, would not survive the next re-pin.

The rewrite probes `crates/common/protos` before `crates/protos/protos`, adds the four missing trees, validates every source tree before it removes the destination, and states the check-out-the-pin-first rule in the header.

## The Corrected Lessons Entry

The I12 entry in `## Recent` claimed the vendored tree tracks checkout HEAD and that the tag predates the cloud protos.
It is replaced with an F5 entry that states where the trees actually live at the tag, how to ask the tag rather than guess a directory, the three upstream prefix mappings, and the one file that had drifted with the reason the drift matters.

## Deviations from Plan

- Plan said: Scope lists five artifacts (the vendored protos, Core/Proto.pm, Client/Connection.pm, t/unit/raw_service_extra.t, .ai-sessions/lessons.md).
- Deviated: also rewrote sdk/xt/author/vendor-protos.pl, which was not in the artifact list.
- Impact: the tool hardcoded the POST-tag proto root `crates/protos/protos`, the exact path whose absence at v0.4.0 produced the false "the tag predates the cloud protos" claim F5 undoes, and it copied only api_upstream, local, and google/rpc.
  Running it, which Core/Proto.pm's own die message tells you to do, would have wiped share/proto, deleted all 19 re-vendored cloud/testservice/health/openapiv2 files, and re-vendored the rest from whatever the checkout was sitting on.
  Without this the F5 end state ("every vendored file byte-identical to the tag") would not survive the next re-pin.
  The rewrite probes `crates/common/protos` before `crates/protos/protos`, adds the four missing trees, and states the check-out-the-pin-first rule.
  Verified by running the fixed tool against a `git archive v0.4.0` extraction in the scratchpad: `diff -rq` against sdk/share/proto reports only `workflow_activation_fq.proto`, which sdk-rust generates into the working tree and keeps out of git (noted in the script header).

- Plan said: sub-step 3, "add a test that schema() before any cloud use does not contain the cloud service while a CloudService handle construction makes it resolvable" IF the lazy-load probe succeeds.
- Deviated: no such test; the probe failed, so eager loading stays and the measured cost is documented in Core/Proto.pm POD (the plan's stated fallback).
- Impact: none on scope.
  Two independent blockers, both confirmed this session: `Protobuf::Schema::resolve` latches on `$resolved` with no reset (Schema.pm:93), so files added by `add_file` after the first resolve are indexed but never type- or feature-resolved; and a second schema is not an isolation because `temporal/api/cloud/nexus/v1/message.proto` (line 12), which `temporal/api/cloud/cloudservice/v1/request_response.proto` pulls in at its line 17, imports `temporal/api/common/v1/message.proto`, so generating it would reinstall the shared `Temporalio::Proto::Api::Common::V1::*` classes over the live ones.
  Measured cost (warm cache, two runs each): 67 files / 1.73s and 1.85s / 40 MB peak RSS without the cloud, testservice, and health roots; 87 files / 2.26s and 2.52s / 45 MB with them.

- Plan said: nothing about a regression test for the vendored vintage.
- Deviated: added a `raw_service_extra.t` subtest asserting `PublicConnectivityRule` has no fields at the pinned tag, with `PrivateConnectivityRule`'s three fields as the control.
- Impact: the byte comparison against the tag is an out-of-band `cmp` that no suite repeats, so nothing would catch a future re-vendor from HEAD.
  This pins the one field that actually drifted, with no dependency on a sibling checkout.
  Proved load-bearing: re-adding `enable_stable_ips` to the vendored file fails subtest 5, and the file was then restored byte-identical to the tag.

### Fix-loop iter 1

- Plan said: nothing; these are validator findings against the F5 diff.
- Deviated: applied the one warn and both infos from the Fable iter-1 block.
- Impact: three changes, none to a vendored `.proto`.

1. `docs.citation-accuracy` (warn, Core/Proto.pm POD): the second-schema paragraph named `cloudservice/v1/request_response.proto` as the importer of `temporal/api/common/v1/message.proto`, which it is not.
   Confirmed by grep over the vendored cloud tree: the only direct importer is `temporal/api/cloud/nexus/v1/message.proto` line 12, reached from `request_response.proto` line 17.
   Reworded in the POD and in the Step F5 entries above; the conclusion (a second schema would reinstall the shared `Api::Common::V1::*` classes) is unchanged, only the file named on the path there.
2. `tooling.validate-before-destroy` (info, xt/author/vendor-protos.pl): the per-tree `-d` check lived inside the copy loop, after `remove_tree($dest)`, so a source root present but missing one subtree emptied `share/proto` and then died.
   Hoisted the check into its own loop over `@trees` ahead of the wipe.
   Re-verified from a scratchpad copy of the script against a `git archive v0.4.0 crates/common/protos` extraction, destination inside the scratchpad, never the repo's `share/proto`: (a) with all eight trees present it vendored 85 files and `diff -rq` against `sdk/share/proto` reported only `workflow_activation_fq.proto`, the file sdk-rust generates into the working tree and keeps out of git; (b) with `grpc` removed from the extraction it died with `expected source tree missing: .../grpc` and exit 2, leaving an already-populated destination at its full 85 files, and in the destination-absent case not creating the directory at all.
3. `tests.error-path-coverage` (info, t/unit/raw_service_extra.t): added a subtest driving `rpc_call` with `service => 'nope'` and pinning the Argument throw plus its anchored `expected one of cloud, health, operator, test, workflow` text, which nothing read after the lookup moved behind `_service_code`/`_service_names`.
   The suggested `runtime => undef, ptr => 1` construction does satisfy ADJUST and never reaches FFI (`_free_client` requires a defined runtime), but a defined `$ptr` makes DESTROY emit the free-without-close warning into the test output, so the fixture uses `runtime => undef, connect => sub { die ... }` instead.
   `rpc_call` runs the service lookup before it awaits `connected_ptr`, so the coderef doubles as the assertion that the guard fires first, and a pointerless connection is reclaimed silently.
   Mutation-checked: changing the message to `pick one of` fails the new subtest.

### Fix-loop iter 2

The validator returned clean.

## Key Actions

- Asked the tag directly with `git ls-tree -r --name-only v0.4.0`, which found all four proto trees under `crates/common/protos/` and disproved the I12 provenance claim in one command.
- Re-vendored 19 files from the tag path with the three upstream prefix mappings; 18 were already identical and `connectivityrule/v1/message.proto` reverted to the tag's empty `PublicConnectivityRule`.
- Exposed `%RPC_SERVICE` through `_service_code` and `_service_names`, routed `rpc_call` through both, and pinned 1 through 5 against the C header.
- Probed lazy loading, found two independent blockers, measured the eager cost, and documented it in POD instead.
- Rewrote the author vendoring script so the next re-pin reproduces this end state rather than destroying it.
- Replaced the false I12 lessons entry with the corrected provenance rule.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| `/goal @goal.md` (orchestrator, F5 implement) | Executed plan.md Section 6 Step F5 sub-steps 1-5 | Dirty tree, both suites green, ready for validation |
| Validator dispatch, iter 1 | Reviewed `git diff HEAD` against the section Tools block | verdict `warn`: one POD citation, two hardening infos |
| Executor `mode=fix`, iter 1 | Corrected the POD citation, hoisted the source-tree validation ahead of the wipe, added the unknown-service subtest | Applied 3, deferred 0, suites green |
| Validator dispatch, iter 2 | Re-reviewed | verdict `clean` |
| Executor `mode=finalize` | Session summary, one signed commit, push | This commit |

## Efficiency Insights

**What went well:**

- One `ls-tree` against the tag settled a provenance question that a directory check had answered backwards.
- The 18-of-19 identical result meant the blast radius could be stated exactly rather than estimated.
- Probing the lazy load to failure, and recording the two blockers by file and line, turns a rejected optimization into a documented decision the next reader does not have to re-derive.

**What could improve:**

- The plan's artifact list did not include the vendoring script, so the tool that would have undone the whole step was found only by reading it.
  A step that changes vendored output should list the tool that produces that output as an artifact by default.

**Course corrections:**

- The lazy-load sub-step was written as conditional on a probe, and the probe failed.
  Took the plan's stated fallback rather than forcing the optimization.

## Process Improvements

- To learn what a tag contains, query the tag.
  A path check inside a working tree answers a question about the working tree's layout, which is a different question, and a crate that moved between the tag and HEAD makes the two answers disagree silently.
- A correction commit should also fix the tool that would recreate the defect.
  Otherwise the end state holds only until someone runs the documented procedure.
- When a claim recorded in `lessons.md` turns out to be false, replace the entry rather than adding a sibling.
  Two entries that disagree cost the next reader the whole investigation again.

## Observations

- The bad provenance produced exactly one drifted field across 19 files, which is why it survived review: almost everything matched, and the part that did not was a field the bridge would silently discard rather than error on.
- A destructive tool that validates its inputs after it deletes the destination has a failure mode strictly worse than not running at all.
- `%RPC_SERVICE` being a file lexical is what let the test comments describe discriminator values nothing checked.
  Exposing the table to a reader was enough to make the existing prose into assertions.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: F6 makes fork-pool frame pairing token-exact, which is activity heartbeat and cancellation semantics.
