# Lessons Learned

## Recent
<!-- 10 most recent lessons, newest first -->
- Verify MUST-match wire constants (payload encodings, gRPC code maps, defaults) by grepping the reference SDK source yourself — Explore subagents paraphrase (reported "json/proto"; actual constant is "json/protobuf") (2026-06-10)
- Read the actual sdk-core C bridge header before specing or planning FFI work — it alone revealed by-value tagged unions in WorkerOptions and the absence of a buffered-metrics API (2026-06-10)
- Cross-check new-SDK semantics against at least two reference SDKs (Python for workflow semantics, Ruby for worker architecture) — single-source review missed RemoveFromCache eviction and the cancel-vs-fail completion command (2026-06-10)
- When a parallel tool batch partially fails (e.g. classifier outage), re-dispatch only the cancelled calls — results from the surviving calls in the batch remain valid (2026-06-10)
- To write files larger than one response allows, end each chunk with a unique marker comment and append via Edit on the marker (2026-06-10)
