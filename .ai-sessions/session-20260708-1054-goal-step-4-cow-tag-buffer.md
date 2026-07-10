# Session Summary: R28 Stop Writing Through a COW-Shared Tag Buffer

**Date**: 2026-07-08
**Duration**: ~20 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (empirical COW probes, one RED/GREEN cycle, one full-suite run, one xt run)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (step complete, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R28, four sub-items)

## Key Actions

- The step-45 probe `verify-45/memsafe-infra/cow_tag.pl` is gone from the tree and git history, so the corruption mode was re-established empirically before designing the test.
  Three Devel::Peek probes pinned down the exact blast radius: a `my $tag_slot = "\0"` scalar is COW with its own op-tree constant (two separate `"\0"` literals do NOT share a PV), a foreign write through `scalar_to_buffer` poisons that constant so every later execution of the same line is born corrupted, and it also corrupts any scalar COW-assigned from the slot before the write.
  The runtime `"\0" x ($stride * $cap)` drain buffers are NOT COW (the repeat writes straight into the lexical's private PV), so only the two 1-byte tag slots carry the hazard, exactly as the plan scoped it.
- RED: created `sdk/t/unit/cow-tag-buffer.t` with three subtests.
  The two site subtests drive the real SDK service subs (`SlotSupplierRegistry->_service_requests`, `Callback::_service_meter_requests`) with a mocked `*_next_request` that performs exactly the shim's one-byte write (`lib.rs` `*out_tag = req.tag`) through the raw tag pointer, then a second pass whose mock peeks the fresh slot's initial byte: pre-fix it read `2A` (poisoned constant), the RED failure.
  Each also asserts an independently created `"\0"` scalar stays untouched (the acceptance-criterion wording), and the file carries the audit note classifying all six `scalar_to_buffer` sites in sdk/lib (two fixed, two non-COW by construction, two read-only).
- GREEN + REFACTOR (one motion, the plan's refactor IS the single helper, the R3 precedent): added `Temporalio::Core::FFI::private_write_buffer($slot, $size)` next to `keep_buffer`.
  It fills the caller's scalar in place through the `@_` alias, uses `FFI::Platypus::Buffer::grow` (v2.11) to detach any COW buffer, pins NUL content with a 4-arg substr splice on the now-private PV, and returns the writable pointer.
  Both tag-slot sites (`Core/Callback.pm` `_service_meter_requests`, `Worker/SlotSupplierRegistry.pm` `_service_requests`) now route through it; comments at all three places cite finding L4 / spec R28.
  The alias-fill shape avoids return-by-value, where Perl's swipe-vs-COW copy behavior for sub returns is version-dependent.
- Verify: `prove -l t/unit/cow-tag-buffer.t` green; full `prove -lj4 t` green (108 files, 566 tests, integration ran live against a dev server); `prove -lj4 xt` green (314 tests). Not shim-touching, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R28 | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Rebuilding the lost probe empirically (three one-liner Devel::Peek/memset probes) before writing the test surfaced the real corruption target: the op-tree constant, not a cross-file literal sibling.
  That produced a sharper RED assertion (peek the next fresh slot's initial byte) than the acceptance criterion's literal wording alone, which can never fail cross-file since separate literals don't share PVs.
- Validating the exact helper shape (alias fill + grow + substr, called cross-package) in a standalone probe before touching the SDK meant GREEN worked first try.

**What could improve:**
- First drafts of the new comments used em-dashes to match the surrounding file style; the global writing rules prohibit them, so a scrub pass was needed. Write them clean the first time.

**Course corrections:**
- None beyond the em-dash scrub.

## Observations

- Perl's `SV_COW_THRESHOLD` means short runtime strings are plain-copied on assignment, so a copy taken from the grown slot never re-shares the PV; only compile-time literal constants are born COW at 1 byte. That is why the drain buffers were safe all along.
- `FFI::Platypus::Buffer::grow` docs note pointers taken before growing become invalid: the helper's grow-then-scalar_to_buffer order matters.
- Plan line refs for the Callback.pm site (362-363) had drifted to 385-386; the finding refs are kept as citations in comments while the code names the subs.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: next step (R16, evict iteration safety in Workflow/Runner.pm) is workflow-semantics territory; the determinism references apply.
