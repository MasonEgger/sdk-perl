# Handoff: Kick off the autonomous Phase 0 implementation run

## Current State

- **Branch**: `v1`, up to date with `origin/v1`. Last commit `17db572 adding CLAUDE.md` (pushed).
- **Phase**: pre-implementation → starting implementation. Spec + plan + todo are committed; Phase 0 code does not exist yet.
- **Queued next**: run the autonomous `/bpe:goal full` loop to execute `todo.md` (170 unchecked `- [ ]` sub-items, P0.1–P5.5) on branch `v1`, model `claude-opus-4-8`. Test command: `cd sdk && prove -lj4 t`.
- **Files in flight (uncommitted)**: `sdk/t/00-load.t` — untracked. It is the partial P0.1.1 RED deliverable written by a prior `bpe:step-executor` dispatch that could not verify/commit (Fable classifier outage at the time). The resumed P0.1.1 step must verify it fails for the right reason (`cd sdk && prove -l t/00-load.t` — `Temporalio::SDK` doesn't exist yet), then proceed to GREEN and commit it. Until then `git status --short` is non-empty.

## Open Decisions and Blockers

- **Model routing (decided)**: implementation runs on `claude-opus-4-8` (oracle-rich, stable, cheaper); Fable 5 was reserved for oracle-free spec/planning and is 2x cost. The earlier Fable classifier outage that blocked Bash/Skill/subagent dispatch is the reason the first P0.1.1 dispatch returned a `Failure:` block. On Opus this should not recur.
- **Binary version**: installed `claude` is `2.1.170`; a long-lived session may be running an older binary. Recommend restarting (`claude --continue`) before the long autonomous loop so it runs on the current engine with freshly reloaded plugins. `/bpe:goal` requires Claude Code v2.1.139+ (satisfied).
- **Open technical risk**: WorkerOptions struct marshalling (by-value tagged unions through FFI::Platypus) — risk spike 3, plan step P0.10, spec §11. `pack()` fallback noted. Not yet started.

## Suggested Goal

```
Suggested Goal: /bpe:goal full
```

Full pre-built condition (branch `v1`, runner `cd sdk && prove -lj4 t`):

> Every item in todo.md is checked off; `cd sdk && prove -lj4 t` exits 0 with no failing tests; git status --short is empty; all commits are pushed to origin/v1; .ai-sessions/lessons.md contains any new lessons captured during the run.

Pre-flight is green: branch `v1` (not main), plan.md/todo.md present, 170 unchecked, `commit-msg.md` gitignored. The orchestrator dispatches `bpe:step-executor` per unchecked item; the parent must NEVER `/clear` or `/compact`. Run `/auto` before pasting the `/goal` block (subagents inherit parent auto-mode). Commit ritual per `~/.claude/rules/git-workflow.md`: session-summary → commit-message → `git commit -S -F commit-msg.md`; never stage `commit-msg.md`; NEVER commit to main.

## Suggested Skills for the Next Session

- `temporal:temporal-developer` — P0.x needs Temporal runtime/worker lifecycle semantics kept spec-true.
- `bpe:execute-plan` — the per-step TDD procedure the step-executor follows.

## Pointers, Not Content

- Contract: `spec.md` (§0 prime directive, §3 shim, §4.6 protobuf-perl, §8 poll loops, §10.3 job ordering, §11 risk spikes).
- Plan/tracker: `plan.md` (34 steps P0.1–P5.5), `todo.md` (170 checkboxes).
- Project conventions + architecture: `CLAUDE.md`.
- Last session record: `.ai-sessions/session-20260610-0831-spec-audit-plan.md`.
- Cross-session lessons: `.ai-sessions/lessons.md` — esp. "verify MUST-match wire constants by grepping reference SDK source yourself" and "read the actual sdk-core C bridge header before specing/planning FFI work".
- Reference SDK checkouts: `../sdk-python`, `../sdk-ruby`, `../sdk-rust`, `../sdk-typescript`; protobuf dep at `/home/mmegger/Code/MasonEgger/proto3-perl/`.
