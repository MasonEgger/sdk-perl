# Session Summary: Goal Step 29 — Workflow definitions + registry (P3.1)

**Date**: 2026-06-13
**Duration**: ~30 minutes (single autonomous subagent dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (<$1 — reference-SDK reads, one RED/GREEN cycle, a
short attribute-handler debugging detour, full-suite run)
**Model**: claude-opus-4-8[1m]

## Goal Context

- **Mode**: step (one `bpe:step-executor` dispatch per todo.md item group)
- **Outcome**: step completed — P3.1.1 RED through P3.1.3 Verify in one
  commit. **First Phase 3 (workflow) step.** Workflow classes can now be
  declared class-style with `:Run` (exactly one entry point), `:Signal`,
  `:Query`, `:Update`, `:UpdateValidator`, and `:Init` attributes; the
  per-class registry (`_workflow_defs`/`_workflow_type`) is populated at the
  subclass's compile time, and `Worker::WorkflowRegistry` resolves a list of
  workflow class names into `{ type => class }` while rejecting duplicate
  types and classes missing a `:Run`.
- **Subagent dispatches**: this summary covers dispatch 29
- **Steps completed**: 3 of 3 P3.1 sub-items (P3.1.1–P3.1.3)

## Key Actions

- MUST-match workflow-definition semantics verified against reference SDK
  source per CLAUDE.md (quoted below):
  - **Exactly one run method; duplicate handlers invalid** — sdk-python
    `temporalio/workflow/_definition.py` 297 `"Multiple @workflow.run methods
    found (at least on {name} and {run_fn.__name__})"`; 312/324/347 `"Multiple
    signal/query/update methods found for {defn_name} ..."`; 408 `"Missing
    @workflow.run method"` when `not seen_run_attr`. sdk-ruby
    `workflow/definition.rb` 342 `"Workflow #{handler[:type].name} ... defined
    on ..."` and per-kind dedup in the `@workflow_signals`/`_queries`/`_updates`
    hashes. The Perl base raises `Temporalio::Exception::Argument` with
    matching message shapes: "Multiple :Run methods found on <pkg>",
    "Multiple Signal methods found for <name> on <pkg>".
  - **Default name = method name; explicit override; dynamic precludes name**
    — sdk-python `defn`/`_apply_to_class` uses `name or fn.__name__`; sdk-ruby
    `workflow_signal`/`_query`/`_update` (definition.rb 148/176/206) all `raise
    'Cannot provide name if dynamic is true' if name && dynamic`. The Perl
    `:Signal`/`:Query`/`:Update` default to the method name, accept
    `('foo')`/`(name=foo)` overrides, and `(dynamic=1)` (which must not carry a
    name) routes to the per-kind dynamic slot.
  - **Workflow type default = class basename for `run`** — sdk-python
    `workflow_name=name or cls.__name__`. The Perl SDK refines this per spec
    section 8.6: a `:Run` method named `run` defaults the workflow type to the
    **class basename**; any other `:Run` method defaults to the **method
    name**; `:Run('Custom')` overrides.
  - **`:Init` constructor hook** — sdk-python `workflow.init` (`__init__` only,
    params must match `run`); sdk-ruby `workflow_init` ("must be placed above
    the initialize method"). P3.1 only needs registration of the hook; the
    param-match enforcement and execution land with the runner (P3.3).
  - **Duplicate workflow type in a worker (T-wkr-2, workflow side)** —
    sdk-python `worker/_workflow.py` raises on a repeated type name; the Perl
    `Worker::WorkflowRegistry` raises `Argument` "More than one workflow named
    '<type>'".
- Reused the proven section 10.1 attribute pattern from P2.1 (activities):
  every handler is `:ATTR(CODE,BEGIN)` and lives inside the `class`-declared
  base `Temporalio::Workflow::Definition` (constraints 1–3); `$data` is
  normalised as arrayref-or-undef (constraint 4). The spike proofs in
  `sdk/t/spike/` and the regression in `t/unit/attribute_handlers.t` remain
  untouched.
- RED (P3.1.1): `sdk/t/unit/workflow_definition.t` — 8 subtests: full
  attribute surface populates `_workflow_defs` (run/signals/queries/updates/
  init), workflow-type defaults+overrides, two `:Run` rejected at definition
  time, duplicate signal name rejected at definition time, registry builds
  `type => class` from class names, T-wkr-2 duplicate type, missing-`:Run`
  rejected, invalid (non-class) entry rejected. Extra `:isa` fixtures live in
  `sdk/t/lib/WfDef/{CustomRun,Plain,TwoRuns,DupSignal,NoRun}.pm` because only
  one `:isa` class parses per file with Future::AsyncAwait loaded (existing
  lesson); loaded via `use lib "$FindBin::Bin/../lib"`.
- GREEN (P3.1.2): `Workflow.pm` (author entry point that loads the base),
  `Workflow/Definition.pm` (base class + all six attribute handlers +
  `_workflow_defs`/`_workflow_type` + duplicate detection),
  `Workflow/Attributes.pm` (`parse_handler` for Signal/Query/Update naming +
  dynamic; `parse_run` for the basename-vs-method-name-vs-override workflow
  type), and `Worker/WorkflowRegistry.pm` (resolves class names → type =>
  class, requires a `:Run`, rejects duplicate types and non-class entries).
- Verify (P3.1.3): targeted file green (8 subtests), then full suite
  `prove -lj4 t` → 30 files, 187 tests, exit 0 (integration ran live, not
  skipped).

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo item (P3.1 workflow definitions + registry), verify run/signal/query/update naming + duplicate detection + :Init against sdk-python + sdk-ruby, obey section 10.1 attribute constraints | Ground-truth reads (workflow/_definition.py _apply_to_class, ruby definition.rb handler dedup), RED unit test (8 subtests + 5 t/lib fixtures), GREEN 4 lib modules, attribute-handler debug detour, full-suite verify, todo update, summary, commit, push | Suite 30 files / 187 tests, exit 0 |

## Efficiency Insights

**What went well:**
- The section 10.1 attribute pattern was already proven for activities, so the
  six workflow handlers worked structurally first try — no spike needed.
- Quoting the exact python/ruby duplicate-detection and naming lines up front
  made the message shapes and the "run -> basename, other -> method name"
  split correct without iteration.

**What could improve:**
- The first `WfDef::CustomRun` fixture wrote `:Run ($x)` (no override arg) but
  the test expected the workflow type `CustomWorkflow` — a fixture typo, not a
  code bug. The ABOUTME comment had the right intent; the code line dropped the
  `('CustomWorkflow')`. Caught it by tracing `$data` through `parse_run`.
- Spent a few minutes chasing a phantom "quoted-string attribute arg lost on
  require" bug before realising the fixture simply omitted the arg. Verifying
  the raw bytes of the fixture line (`cat -A`) is the fast disambiguator.

**Course corrections:**
- Discovered that a `die`/throw escaping a BEGIN-phase attribute handler during
  `require` is stringified by the Perl compiler, so the blessed
  `Exception::Argument` cannot survive across the require boundary. Adjusted the
  two compile-time-rejection subtests to assert on the (durable) message rather
  than the blessed class, and documented why in the test. The blessed-object
  contract is still asserted on the runtime registry path (T-wkr-2).

## Process Improvements

- For compile-time (BEGIN-phase) attribute-handler validation, the testable
  contract across a `require` boundary is the message text, not the exception
  class — the Perl compiler stringifies the thrown object. Assert blessed
  exceptions only on runtime paths (e.g. the registry constructor).
- When a `:Run('Name')`-style override "doesn't take", `cat -A` the fixture
  line first: the override arg is easy to drop while keeping the signature.

## Observations

- `Worker::WorkflowRegistry` lazily `require`s a class-name entry but falls back
  to `->can('_workflow_defs')` for classes already loaded inline (mirrors the
  activity registry), then enforces the `:Run` requirement at registration so a
  malformed workflow is rejected before the worker runs.
- `_workflow_defs` returns a normalised hash with all buckets present (signals/
  queries/updates/validators/dynamic default to `{}`), so downstream runner
  code (P3.3+) can index without existence checks.

## Suggested Skills for Next Session

- No matching skill for the next step (P3.2 `Temporalio::Workflow::Future` is a
  pure `Future` subclass — manual resolve drives awaiting continuations
  synchronously, `on_cancel` hooks fire in reverse order, `is_workflow_future`
  flag; spec section 10.3, no FFI). The `temporal:temporal-developer` skill is
  end-user usage guidance, not SDK internals — invoked this dispatch per
  execute-plan step 3 but not load-bearing. Ground truth for P3.2: spec section
  10.3 "Workflow::Future" block and the `Future` CPAN module's subclass surface.
