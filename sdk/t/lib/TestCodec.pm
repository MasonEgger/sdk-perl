# ABOUTME: Umbrella loader for the test-only payload codecs used by
# ABOUTME: converter_data.t: TestCodec::{Xor,Recorder,Dying}.
use v5.38;
use warnings;

# NOTE: one class per file, deliberately. With Future::AsyncAwait loaded
# (0.71, perl 5.38.2) — and Temporalio::Converter::Data loads it — only the
# FIRST `class Name :isa(...)` declaration per file parses; the next one in
# the same file dies with "Cannot create class ... non-empty @ISA" or
# "Subroutine attributes must come before the signature" (leaked attribute
# parser state). See .ai-sessions/lessons.md.
use TestCodec::Xor;
use TestCodec::Recorder;
use TestCodec::Dying;

1;
