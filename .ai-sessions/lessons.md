# Lessons Learned

## Recent
<!-- 10 most recent lessons, newest first -->
- FFI::Platypus `record(Class)` (no `*`) passes AND returns structs by value — small by-value returns like TemporalCoreRuntimeOrFail work directly on x86-64, no shim out-param needed; `record(Class)*` is the pointer form; nested records are unsupported by FFI::Platypus::Record, so flatten embedded structs into layout-identical scalar fields (2026-06-11)
- Alien::Build runs alienfiles via `do '<abs path>'`, so `__FILE__` inside an alienfile is the real path — walk up from it to locate in-tree sources (works from a checkout AND a dzil .build dir); Test::Alien::Build's `alien_build_ok` monkeypatches `${class}::dist_dir` to the test prefix, so dist_dir-derived accessors like `include_dir` work under test (2026-06-11)
- cbindgen turns `#[repr(C)] struct Foo { _private: [u8; 0] }` into a zero-size struct DEFINITION that conflicts with the foreign header's real definition — for borrowed foreign types use `[export] exclude` plus `after_includes` forward typedefs in cbindgen.toml (2026-06-11)
- `[@Starter::Git]` uses Git::GatherDir, which gathers only git-TRACKED files — `git add` a new distribution's files before its first `dzil test` or the build dir will be missing them (symptom: `[AlienBuild] No alienfile!`) (2026-06-11)
- An alienfile local-path override needs a NON-EMPTY stub download dir (else Extract::Directory dies "no files extracted") plus an `install_prop->{download_detail}{$path} = { protocol => 'file' }` entry so the digest stage accepts the trusted local fetch (2026-06-11)
- The `:reader` field attribute is Perl 5.40+ — on this project's 5.38 floor write explicit one-line reader methods; spec sketches like `method message :reader;` are aspirational syntax, so verify each construct against 5.38 before coding (2026-06-11)
- `prove t` does NOT recurse into `t/unit/` etc. — `sdk/.proverc` carries `--recurse` so the documented `prove -lj4 t` runs the whole tree; after adding a test in a new subdir, check prove's file list, not just PASS (2026-06-11)
- Despite the mandatory `use utf8` test preamble, Test2's TAP formatter handle is not UTF-8 — non-ASCII in test names emits `Wide character in print`; keep test names ASCII (2026-06-11)
- Test2::V1 with a bare `use` exports ONLY `T2()` — no `ok`/`is`/`done_testing` barewords; the spec §12.1 preamble therefore implies the `T2->method` style for every test file. `require_ok` does not exist anywhere in Test2 (it is Test::More-only) — use `my $ok = eval { require M; 1 }; T2->ok($ok, ...)` (2026-06-10)
- List-context collapse in T2 method args is a recurring trap: a failed `eval {}` AND an FFI::Platypus::Record opaque accessor reading NULL both return the empty list, shifting the test name into the value slot. Assign to a lexical first; a missing test name in TAP output is the tell (2026-06-11)
## Workflow
- Verify MUST-match wire constants (payload encodings, gRPC code maps, defaults) by grepping the reference SDK source yourself — Explore subagents paraphrase (reported "json/proto"; actual constant is "json/protobuf") (2026-06-10)
- Read the actual sdk-core C bridge header before specing or planning FFI work — it alone revealed by-value tagged unions in WorkerOptions and the absence of a buffered-metrics API (2026-06-10)
- Cross-check new-SDK semantics against at least two reference SDKs (Python for workflow semantics, Ruby for worker architecture) — single-source review missed RemoveFromCache eviction and the cancel-vs-fail completion command (2026-06-10)
- When a parallel tool batch partially fails (e.g. classifier outage), re-dispatch only the cancelled calls — results from the surviving calls in the batch remain valid (2026-06-10)
- To write files larger than one response allows, end each chunk with a unique marker comment and append via Edit on the marker (2026-06-10)

## Rust
- cbindgen renders opaque `_private: [u8; 0]` structs as zero-size definitions; borrowed foreign types need `[export] exclude` + `after_includes` forward typedefs to coexist with the owning header (2026-06-11)

## Perl
- FFI::Platypus `record(Class)` is by value (returns included), `record(Class)*` by pointer; FFI::Platypus::Record cannot nest records — flatten embedded structs to layout-identical fields (2026-06-11)
- Alien::Build runs alienfiles via `do '<abs path>'` (`__FILE__` is real — usable to locate in-tree sources); Test::Alien::Build's `alien_build_ok` monkeypatches `${class}::dist_dir`, so dist_dir-derived accessors work under test (2026-06-11)
- `field $x :reader` requires Perl 5.40+; on the 5.38 floor declare explicit reader methods inside the class block (2026-06-11)

## Testing
- `prove t` is non-recursive by default; this repo's `sdk/.proverc` adds `--recurse` so subdirectory tests run under the documented command (2026-06-11)
- Test names must stay ASCII — Test2's TAP handle is not UTF-8 even though test files `use utf8` (2026-06-11)
- Test2::V1 bare `use` exports only `T2()`; use `T2->method` style per spec §12.1, and emulate `require_ok` with `eval { require M; 1 }` into a lexical (2026-06-10)
- Never pass an expression that can return the empty list (`eval {}`, FFI::Platypus::Record opaque accessors on NULL) directly as a T2 method argument — list-context collapse shifts the test name into the value slot (2026-06-11)
