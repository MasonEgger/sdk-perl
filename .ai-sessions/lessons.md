# Lessons Learned

## Recent
<!-- 10 most recent lessons, newest first -->
- Test2::V1 with a bare `use` exports ONLY `T2()` — no `ok`/`is`/`done_testing` barewords; the spec §12.1 preamble therefore implies the `T2->method` style for every test file. `require_ok` does not exist anywhere in Test2 (it is Test::More-only) — use `my $ok = eval { require M; 1 }; T2->ok($ok, ...)` (2026-06-10)
- `T2->ok(eval { ... }, $name)` is a silent false-pass trap: method-call args are list context, a failed eval collapses to the empty list, and $name shifts into the boolean slot. Assign the eval to a lexical first; a missing test name in TAP output is the tell (2026-06-10)
- Verify MUST-match wire constants (payload encodings, gRPC code maps, defaults) by grepping the reference SDK source yourself — Explore subagents paraphrase (reported "json/proto"; actual constant is "json/protobuf") (2026-06-10)
- Read the actual sdk-core C bridge header before specing or planning FFI work — it alone revealed by-value tagged unions in WorkerOptions and the absence of a buffered-metrics API (2026-06-10)
- Cross-check new-SDK semantics against at least two reference SDKs (Python for workflow semantics, Ruby for worker architecture) — single-source review missed RemoveFromCache eviction and the cancel-vs-fail completion command (2026-06-10)
- When a parallel tool batch partially fails (e.g. classifier outage), re-dispatch only the cancelled calls — results from the surviving calls in the batch remain valid (2026-06-10)
- To write files larger than one response allows, end each chunk with a unique marker comment and append via Edit on the marker (2026-06-10)

## Testing
- Test2::V1 bare `use` exports only `T2()`; use `T2->method` style per spec §12.1, and emulate `require_ok` with `eval { require M; 1 }` into a lexical (2026-06-10)
- Never pass `eval {}` directly as a `T2->ok` argument — list-context collapse on failure shifts the name into the boolean slot and false-passes (2026-06-10)
