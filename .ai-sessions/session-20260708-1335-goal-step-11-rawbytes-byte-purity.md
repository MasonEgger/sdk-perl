# Session Summary: R6 RawBytes Byte Purity at the FFI Boundary

**Date**: 2026-07-08
**Duration**: ~20 minutes (one autonomous step-executor dispatch)
**Conversation Turns**: 1 orchestrator dispatch
**Estimated Cost**: low (one RED file, two lib edits, one POD edit, one full-suite run, one xt run, no cargo work)
**Model**: Fable 5

## Goal Context

- **Condition**: execute the next unchecked todo.md item from the R1-R97 remediation plan
- **Mode**: step (autonomous /bpe:goal dispatch)
- **Outcome**: converged (step complete, suites green)
- **Subagent dispatches**: 1
- **Steps completed**: 1 of 1 (step R6, four sub-items)

## Key Actions

- Traced the L21 34-vs-36 mechanism to its dependency root before writing the test: proto3-perl's `bytes` field encoder (`Protobuf/Codec.pm:119`) does a NON-FATAL `utf8::downgrade($bytes, 1)`, so a wide scalar survives downgrade-failure silently and the length varint counts characters while the concatenated frame carries the UTF-8 encoding of them.
The RED file's header comment carries this full code trace.
- RED: `sdk/t/unit/rawbytes_ffi_bytes.t`, three subtests.
(1) Wide-scalar (U+2603) RawBytes takes the either/or acceptance shape: typed-error branch or normalized-and-self-consistent branch; pre-fix it entered the else branch and failed on the UTF8 flag surviving construction and on the frame decoding corrupt.
(2) Upgraded latin-1 scalar ("caf\xE9") must store downgraded octets and frame 4 bytes, not the 5-byte UTF-8 PV; pre-fix failed on both.
(3) keep_buffer framed==written guards for ASCII, embedded-NUL, upgraded latin-1 (pre-fix failed: 9 framed vs 8 octets), and wide-encodes-to-UTF-8.
- GREEN, RawBytes half: `Payload/RawBytes.pm` ADJUST now downgrades a UTF8-flagged latin-1-range scalar in place (byte-identical) and throws `Temporalio::Exception::Argument` for genuine wide characters, with a comment citing spec R6 / finding L21 and the framed==written invariant.
Chose reject-over-encode for wide input: "raw bytes" with codepoints above 0xFF has no byte representation and guessing an encoding would be silent corruption of a different flavor; the error text points the caller at `utf8::encode`.
- GREEN, FFI half: `Core/FFI.pm` keep_buffer normalizes its private copy before `scalar_to_buffer`: downgrade when possible, else deterministic `utf8::encode` (a wide string reaching keep_buffer is text for the bridge, which expects UTF-8); after either branch length($copy) == bytes written.
- REFACTOR: character-vs-byte audit of every `scalar_to_buffer` site recorded in the keep_buffer doc block: private_write_buffer (NUL-filled private PV, no character semantics), Callback.pm drain and _drain_meter_records (`"\0" x N` buffers, pure bytes by construction), LoggingConfig.pm to_ffi (pointer and size from the same PV, UTF-8 PV correct for the Rust env-filter).
R28 owns the COW-write variant.
RawBytes POD rewritten to document the byte-purity contract and the typed error.
- Verify: new file green (3 subtests, 16 assertions); full `prove -lj4 t` green (117 files, 590 tests); `prove -lj4 xt` green (314 tests).
Not shim-touching, no cargo work.

## Prompt Inventory

| Prompt/Command | Action Taken | Outcome |
|---|---|---|
| Orchestrator dispatch: execute next todo.md item | Full RED/GREEN/REFACTOR for step R6 | Step complete, one commit |

## Efficiency Insights

**What went well:**
- Reading the proto3-perl Codec.pm encoder before writing the test turned the probe's opaque "34 vs 36" into a precise two-site failure story, which made the RED assertions land on the first run.
- The cow-tag-buffer.t audit-note pattern (enumerate every call site with a verdict in a comment) transferred directly to the R6 character-vs-byte audit.

**What could improve:**
- Nothing notable; the verify-45 probe scratchpad being gone cost nothing because the spec and plan carried the needed detail.

**Course corrections:**
- None.

## Observations

- `scalar_to_buffer` on a UTF8-flagged scalar is internally self-consistent (UTF-8 PV pointer plus PV byte size), so the outer ByteArrayRef never mismatches; the corruption is the INNER proto varint framed upstream with character semantics.
The wide-RawBytes subtest's "framed length equals bytes written" assertion passed even pre-fix for exactly this reason; the decode-cleanly assertions are what catch the inner corruption.
- `feature 'class'` ADJUST blocks can mutate a `:param` field in place (`utf8::downgrade($bytes, 1)` works on the field lexical), which made the downgrade-at-construction fix a two-line change.

## Suggested Skills for Next Session

- `temporal:temporal-developer`: the next step (R7, extending the payload codec boundary to the full v0.2 surface) is Python-parity codec work across nine workflow surfaces.
