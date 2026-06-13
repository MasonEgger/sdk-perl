# Session Summary: Correct stale patching status in spec.md

**Date**: 2026-06-13
**Duration**: short follow-up (~2 turns)
**Conversation Turns**: ~2
**Estimated Cost**: low
**Model**: Opus 4.8

## Key Actions

- Removed workflow versioning (`patched` / `deprecate_patch`) from the spec §15
  "Explicitly deferred to v0.2+" list — it was implemented in P3.8 and is exercised
  by `t/replay/determinism.t` (`NotifyHasPatch` / `SetPatchMarker`), so listing it as
  deferred was inaccurate.
- Updated the §10.2 context-API comment from "Versioning (Phase 6+)" to note that
  patching is implemented in v0.1, cross-referencing §10.5.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| "fix the stale spec line" | Edited spec.md §10.2 + §15 | Patching now documented as v0.1, not deferred |

## Observations

- Child-workflow lines in §10.2 remain correctly marked "Phase 6+ / deferred"; only
  the patching status was stale.
- The README's "Not yet supported" section was already accurate (it documents
  patching as available), so no doc change was needed there.

## Suggested Skills for Next Session

- None.
