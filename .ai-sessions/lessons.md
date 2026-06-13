# Lessons Learned

## Recent
<!-- 10 most recent lessons, newest first -->
- With Future::AsyncAwait loaded (0.71, perl 5.38.2) — even `use Future::AsyncAwait ()` with no import — only the FIRST `class X :isa(Y)` per file parses; the next dies with "Subroutine attributes must come before the signature" or "non-empty @ISA". Keep one `:isa` class per file; codec/test classes that must share a file can skip the `async` sugar and return `Future->done/fail` directly (2026-06-12)
- The C bridge header alone under-specifies semantics — read the bridge's .rs conversion code too (testing.rs: an EMPTY download_version becomes `Fixed("")` not SDK-default, so pass the literal 'default'; `ephemeral_server_free` must wait for the shutdown callback because the async block borrows the server box; the spawned CLI inherits stdout/stderr) (2026-06-12)
- A bare `class` file (no preceding `package` statement) compiles file-scope subs into `main::`, so calls from inside the class block fail with "Undefined subroutine &Class::_helper" — define every helper sub INSIDE the `class { }` block (2026-06-12)
- An installed (non-checkout) Protobuf dist cannot auto-resolve its bundled WKTs — Parser.pm's share lookup is checkout-relative but installs land in auto/share/dist/Protobuf — so pass `File::ShareDir::dist_dir('Protobuf') . '/proto'` as an explicit include path (2026-06-12)
- cbindgen tagged unions (#[repr(C)] Rust enums with payload) lay out as {4-byte C-enum tag, pad to union alignment, union sized by largest member}; Perl-side hand-pack is `pack('L x4', $tag) . $variant` zero-padded to the union size — and verify hand-packed layouts with a shim echo function built on #[repr(C)] mirrors copied verbatim from the owning crate (compiler-guaranteed layout, no server needed) (2026-06-11)
- Linux::FD::Event flags use long literals (`'non-blocking'`, `'close-on-exec'`) — spec §4.2's `'nonblock'` sketch is rejected with "No such flag"; spike CPAN flag/option literals in a one-liner before coding against spec sketches (2026-06-11)
- FFI::Platypus::Record drops C trailing padding (TemporalCoreByteArray: 25 bytes vs C's 32) but inserts interior padding correctly — by-pointer field reads are safe, and record sizeof IS a valid array stride iff the final member ends on the struct's max-alignment boundary (probe with sentinel bytes first; CallbackEntry: 64 == C); read struct fields from an opaque ptr by casting `'opaque' => 'record(Class)*'` through the shared FFI instance (2026-06-12)
- FFI::Platypus `record(Class)` (no `*`) passes AND returns structs by value — small by-value returns like TemporalCoreRuntimeOrFail work directly on x86-64, no shim out-param needed; `record(Class)*` is the pointer form; nested records are unsupported by FFI::Platypus::Record, so flatten embedded structs into layout-identical scalar fields (2026-06-11)
- Alien::Build runs alienfiles via `do '<abs path>'`, so `__FILE__` inside an alienfile is the real path — walk up from it to locate in-tree sources (works from a checkout AND a dzil .build dir); Test::Alien::Build's `alien_build_ok` monkeypatches `${class}::dist_dir` to the test prefix, so dist_dir-derived accessors like `include_dir` work under test (2026-06-11)
- cbindgen turns `#[repr(C)] struct Foo { _private: [u8; 0] }` into a zero-size struct DEFINITION that conflicts with the foreign header's real definition — for borrowed foreign types use `[export] exclude` plus `after_includes` forward typedefs in cbindgen.toml (2026-06-11)

## Tooling
- `[@Starter::Git]` uses Git::GatherDir, which gathers only git-TRACKED files — `git add` a new distribution's files before its first `dzil test` or the build dir will be missing them (symptom: `[AlienBuild] No alienfile!`) (2026-06-11)

## Workflow
- The C bridge header declares shapes, but the bridge's .rs conversion code declares semantics (empty-string traps, free-after-callback ordering, stdio inheritance) — read both before writing FFI wrappers (2026-06-12)
- Verify MUST-match wire constants (payload encodings, gRPC code maps, defaults) by grepping the reference SDK source yourself — Explore subagents paraphrase (reported "json/proto"; actual constant is "json/protobuf") (2026-06-10)
- Read the actual sdk-core C bridge header before specing or planning FFI work — it alone revealed by-value tagged unions in WorkerOptions and the absence of a buffered-metrics API (2026-06-10)
- Cross-check new-SDK semantics against at least two reference SDKs (Python for workflow semantics, Ruby for worker architecture) — single-source review missed RemoveFromCache eviction and the cancel-vs-fail completion command (2026-06-10)
- When a parallel tool batch partially fails (e.g. classifier outage), re-dispatch only the cancelled calls — results from the surviving calls in the batch remain valid (2026-06-10)
- To write files larger than one response allows, end each chunk with a unique marker comment and append via Edit on the marker (2026-06-10)

## Rust
- cbindgen renders opaque `_private: [u8; 0]` structs as zero-size definitions; borrowed foreign types need `[export] exclude` + `after_includes` forward typedefs to coexist with the owning header (2026-06-11)

## Perl
- With Future::AsyncAwait loaded (0.71, perl 5.38.2), only ONE `class X :isa(Y)` declaration parses per file (the next gets leaked attribute-parser state) — one `:isa` class per file; subclasses can return `Future->done/fail` directly instead of `async` sugar (2026-06-12)
- Hand-pack C tagged unions as `pack('L x4', $tag) . $variant` zero-padded to the union size (largest member); validate every offset via a shim echo function over #[repr(C)] mirror structs copied from the owning crate (2026-06-11)
- Linux::FD::Event flags use long literals (`'non-blocking'`, `'close-on-exec'`) — spec §4.2's `'nonblock'` sketch is rejected; spike CPAN flag literals before coding against spec sketches (2026-06-11)
- FFI::Platypus `record(Class)` is by value (returns included), `record(Class)*` by pointer; FFI::Platypus::Record cannot nest records — flatten embedded structs to layout-identical fields (2026-06-11)
- FFI::Platypus::Record drops C trailing padding but inserts interior padding correctly — record sizeof is a valid array stride iff the final member ends max-aligned (probe with sentinel bytes first); read struct fields from an opaque ptr via `cast('opaque' => 'record(Class)*', $ptr)` (2026-06-12)
- A bare `class` file (no `package` statement) puts file-scope subs in `main::` — helper subs callable from inside the class must be defined inside the `class { }` block (2026-06-12)
- Alien::Build runs alienfiles via `do '<abs path>'` (`__FILE__` is real — usable to locate in-tree sources); Test::Alien::Build's `alien_build_ok` monkeypatches `${class}::dist_dir`, so dist_dir-derived accessors work under test (2026-06-11)
- `field $x :reader` requires Perl 5.40+; on the 5.38 floor declare explicit reader methods inside the class block (2026-06-11)
- An installed Protobuf dist's WKT auto-include is a no-op (share installs under auto/share/dist/Protobuf, not relative to Parser.pm) — add `File::ShareDir::dist_dir('Protobuf') . '/proto'` to include_paths explicitly (2026-06-12)
- An alienfile local-path override needs a NON-EMPTY stub download dir (else Extract::Directory dies "no files extracted") plus an `install_prop->{download_detail}{$path} = { protocol => 'file' }` entry so the digest stage accepts the trusted local fetch (2026-06-11)

## Testing
- `prove t` is non-recursive by default; this repo's `sdk/.proverc` adds `--recurse` so subdirectory tests run under the documented command (2026-06-11)
- Test names must stay ASCII — Test2's TAP handle is not UTF-8 even though test files `use utf8` (2026-06-11)
- Test2::V1 bare `use` exports only `T2()`; use `T2->method` style per spec §12.1, and emulate `require_ok` with `eval { require M; 1 }` into a lexical (2026-06-10)
- Never pass an expression that can return the empty list (`eval {}`, FFI::Platypus::Record opaque accessors on NULL) directly as a T2 method argument — list-context collapse shifts the test name into the value slot (2026-06-11)
