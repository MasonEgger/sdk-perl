# Temporalio Perl SDK — Implementation Specification (v0.1)

**Status:** Draft for review
**Date:** 2026-05-29 (revised 2026-06-09: protobuf-perl integration,
cross-SDK semantics audit against Python/Ruby + the C bridge header)
**Companion to:** none — the original `PLAN.md` architecture draft has been
retired; this document is the complete contract. (`plan.md` lowercase is the
generated TDD roadmap derived from this spec.)

This document specifies the behavior of the Temporalio Perl SDK at a level of
detail sufficient for TDD. Every component has a Public API, a behavioral
contract, a failure-mode list, and a test-scenario list. `/bpe:plan` converts
this document into a todo list of failing-test-first work items.

---

## 0. Prime directive

**Temporal-spec semantics first. Perl idioms second.**

If a behavior is consistent across two or more existing SDKs (Python, Ruby,
TypeScript, Go, Java, .NET), it is part of the de facto Temporal spec —
mirror it exactly. Perl idioms apply only to surface and presentation:

- Subroutine attribute syntax
- Keyword argument shape
- PEM material accepted as path OR content
- Logger duck-typing
- Test framework choice
- Documentation generation
- Class implementation (`feature 'class'` vs Moo)

Do not deviate from spec on: retry policies, ID reuse/conflict policies,
failure proto mapping, RPC error → exception mapping, activation/command
protocol, data converter chain order, continue-as-new semantics, search
attributes encoding, payload codec composition, heartbeat throttling, cron
scheduling, search-attribute types.

---

## 1. Repository topology

Monorepo at `temporalio/sdk-perl`:

```
sdk-perl/
├── alien-core/                       # Alien-Temporalio-Core distribution
│   ├── alienfile
│   ├── dist.ini
│   └── lib/Alien/Temporalio/Core.pm
├── alien-perl-bridge/                # Alien-Temporalio-PerlBridge distribution
│   ├── alienfile
│   ├── dist.ini
│   └── lib/Alien/Temporalio/PerlBridge.pm
├── sdk/                              # Temporalio-SDK distribution
│   ├── dist.ini
│   ├── lib/Temporalio/...
│   ├── share/proto/                  # Vendored .proto files
│   ├── t/
│   ├── xt/
│   └── examples/
├── ext/
│   └── temporalio-perl-bridge/       # Rust callback shim crate (cdylib);
│                                     # built by Alien-Temporalio-PerlBridge
│       ├── Cargo.toml
│       ├── src/lib.rs
│       └── cbindgen.toml
├── spec.md                           # This file (the contract)
├── plan.md / todo.md                 # Generated TDD roadmap + tracker
└── README.md
```

No CPAN publishing in v0.1. Install pathway:

```
cpanm git+https://github.com/temporalio/sdk-perl.git#main/alien-core
cpanm git+https://github.com/temporalio/sdk-perl.git#main/alien-perl-bridge
cpanm git+https://github.com/temporalio/sdk-perl.git#main/sdk
```

All three distributions use Dist::Zilla with the `[@Starter::Git]`
bundle (`Dist::Zilla::PluginBundle::Starter::Git`, maintained by Dan
Book / Grinnz / DBOOK on CPAN; latest v6.0.0, 2025-12-28).

**Why two Alien distributions?** Per §17 resolution: `sdk-core-c-bridge`
is upstream-tracking (versioned to sdk-rust releases), while
`temporalio-perl-bridge` is our code with its own release cadence.
Bundling them would force the Core Alien to rev every time the Perl-side
trampoline changes, confusing version-tracking. The `Alien-OpenSSL`
(libssl+libcrypto, single upstream tarball) vs separate-Alien pattern
applies here: separate.

---

## 2. Native build — `Alien::Temporalio::Core`

**Purpose:** Compile (or fetch a prebuilt) shared library
`libtemporalio_sdk_core_c_bridge.{so,dylib,dll}` plus the C header, and expose
their filesystem paths to downstream Perl distributions via the `Alien` API.

**Files:** `alien/alienfile`, `alien/lib/Alien/Temporalio/Core.pm`

**Behavior:**

- `alienfile` declares a tarball source pinned to a specific `sdk-rust`
  release tag (initially `v0.4.0` — bump when sdk-core releases).
  Plugin set, explicit: `plugin 'Download' => ( url => '...' )`,
  `plugin 'Digest' => [ SHA256 => '...' ]` (pinned hash),
  `plugin 'Extract' => 'tar.gz'`, `share { build [ ... ] }` with the
  cargo invocation.
- Build step: `cargo build --release -p temporalio-sdk-core-c-bridge`
  from the extracted source tree.
- Install step: copy the compiled cdylib and
  `include/temporal-sdk-core-c-bridge.h` into the Alien share dir.
- `Alien::Temporalio::Core->dynamic_libs` returns the absolute path(s) to the
  compiled library.
- `Alien::Temporalio::Core->include_dir` returns the path to the header
  directory.
- `Alien::Temporalio::Core->version` returns the pinned sdk-rust release
  version string (e.g. `"0.4.0"`).
- **Override hook:** Environment variable
  `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH` — if set and non-empty, skip the
  tarball download/extract and run `cargo build` against the directory
  pointed to. For local dev against
  `/home/mmegger/Code/Temporal/sdk-rust` etc.
- **Probe step:** Always returns "share install required" (we don't reuse
  system installs; the .so is sdk-core-version-specific and never expected on
  the host).

**Failure modes:**

- Tarball download fails (network) → `die` with the URL, the HTTP status, and
  the override-env-var instructions.
- SHA-256 mismatch → `die` with both hashes and a "verify your network or the
  pinned release" message.
- `cargo` not on `$PATH` → `die` with a "install Rust via rustup" message
  including the rustup URL.
- `cargo build` fails → `die` with the cargo output captured verbatim.

**Test scenarios:**

- T-alien-1: With `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH` pointed at a local
  sdk-rust checkout, `cpanm .` succeeds and `Alien::Temporalio::Core->dynamic_libs`
  returns a path to a file that exists and is loadable with `DynaLoader`.
- T-alien-2: Without override and without network, install fails with the
  expected diagnostic.
- T-alien-3: With override set to a non-existent path, install fails with
  "path does not exist" before invoking cargo.
- T-alien-4: After install, `Alien::Temporalio::Core->version` matches the
  pinned tag.

**Dependencies:** `Alien::Build`, `Alien::Build::Plugin::Fetch::HTTPTiny`,
`Alien::Build::Plugin::Extract::CommandLine`, cargo (system).

---

### 2.1 `Alien::Temporalio::PerlBridge`

**Purpose:** Compile the in-tree `temporalio-perl-bridge` cdylib (the Rust
callback shim — see §3) plus its cbindgen-generated header. Depends on
`Alien::Temporalio::Core` at build time (uses its include dir to pick up
`temporal-sdk-core-c-bridge.h`, which the shim's `Cargo.toml` references via
`bindgen` or manual extern declarations).

**Files:** `alien-perl-bridge/alienfile`, `alien-perl-bridge/lib/Alien/Temporalio/PerlBridge.pm`.

**Behavior:**

- Sources from in-tree `ext/temporalio-perl-bridge/`. No tarball fetch —
  the shim is our code and ships with the repo.
- Build: `cargo build --release` inside `ext/temporalio-perl-bridge/`.
- cbindgen generates `include/temporalio-perl-bridge.h` at build time.
- Install: copies the `.so/.dylib` and `.h` into the Alien share dir.
- `Alien::Temporalio::PerlBridge->dynamic_libs` returns the path.
- `Alien::Temporalio::PerlBridge->include_dir` returns the header path.
- Version-locked with the SDK distribution (same git tag).

**Failure modes:**

- `cargo` not on `$PATH` → die with rustup URL.
- Build fails → cargo output captured verbatim.
- `Alien::Temporalio::Core` not installed → die with install instructions
  (the cbindgen step needs the upstream header).

**Test scenarios:**

- T-alien-pb-1: With `Alien::Temporalio::Core` installed, build succeeds
  and `dynamic_libs` returns a loadable shared object.
- T-alien-pb-2: Without core Alien installed, build fails with the
  expected diagnostic.
- T-alien-pb-3: `Alien::Temporalio::PerlBridge->include_dir` contains
  `temporalio-perl-bridge.h` after install.

---

## 3. Rust callback shim — `temporalio-perl-bridge`

**Purpose:** Provide `extern "C"` callback trampoline functions matching the
signatures expected by `sdk-core-c-bridge`'s async APIs (worker poll, complete,
client connect, RPC call, ephemeral server start). Each trampoline pushes
`(callback_id, success_byte_array, fail_byte_array)` into a thread-safe queue
and signals an eventfd (Linux) or pipe (portable fallback). Owns the queue
allocation. **Never calls into the Perl interpreter** — Perl drains the queue
from the main thread when the eventfd reads ready.

**Files:** `ext/temporalio-perl-bridge/Cargo.toml`, `ext/temporalio-perl-bridge/src/lib.rs`,
`ext/temporalio-perl-bridge/cbindgen.toml`,
generated header `ext/temporalio-perl-bridge/include/temporalio-perl-bridge.h`.

**Public C ABI:**

```c
/* Lifecycle */
TemporalioPerlBridgeQueue* temporalio_perl_bridge_queue_new(int32_t signal_fd);
void temporalio_perl_bridge_queue_free(TemporalioPerlBridgeQueue* q);

/* Pair a queue with a Perl-side callback id. The returned pointer is what
 * gets passed as the user_data argument to sdk-core-c-bridge async calls.
 * Single-shot: the trampoline frees it after enqueueing the completion
 * entry. This is how multiple runtimes each route completions to their own
 * queue — user_data is NOT the bare callback id. */
void* temporalio_perl_bridge_user_data_new(TemporalioPerlBridgeQueue* q, uint64_t callback_id);

/* Drain — called from Perl main thread when signal_fd reads ready. Returns
 * number of entries written to out_buf. Each entry is a triplet
 * (callback_id u64, success *const TemporalCoreByteArray, fail *const TemporalCoreByteArray).
 * The byte array pointers must be freed by the Perl side via
 * temporal_core_byte_array_free as documented in sdk-core-c-bridge.h.
 */
size_t temporalio_perl_bridge_queue_drain(
    TemporalioPerlBridgeQueue* q,
    TemporalioPerlBridgeEntry* out_buf,
    size_t out_buf_capacity
);

/* Trampolines — one per sdk-core-c-bridge callback signature. Each reads
 * (queue, callback_id) out of the user_data pair, enqueues the completion
 * entry, frees the pair, and signals the queue's fd. */
void temporalio_perl_bridge_worker_poll_callback(
    void* user_data,
    const struct TemporalCoreByteArray* success,
    const struct TemporalCoreByteArray* fail
);
void temporalio_perl_bridge_worker_callback(
    void* user_data,
    const struct TemporalCoreByteArray* fail
);
void temporalio_perl_bridge_client_connect_callback(
    void* user_data,
    struct TemporalCoreConnection* success,
    const struct TemporalCoreByteArray* fail
);
void temporalio_perl_bridge_client_rpc_call_callback(
    void* user_data,
    const struct TemporalCoreByteArray* success,
    uint32_t status_code,
    const struct TemporalCoreByteArray* failure_message,
    const struct TemporalCoreByteArray* failure_details
);
void temporalio_perl_bridge_ephemeral_server_start_callback(
    void* user_data,
    struct TemporalCoreEphemeralServer* success,
    const struct TemporalCoreByteArray* success_target,
    const struct TemporalCoreByteArray* fail
);
void temporalio_perl_bridge_ephemeral_server_shutdown_callback(
    void* user_data,
    const struct TemporalCoreByteArray* fail
);

/* Pointer accessors — read the static function pointers above so Perl can
 * pass them as the callback argument to sdk-core-c-bridge functions. */
void* temporalio_perl_bridge_worker_poll_callback_ptr(void);
void* temporalio_perl_bridge_worker_callback_ptr(void);
void* temporalio_perl_bridge_client_connect_callback_ptr(void);
void* temporalio_perl_bridge_client_rpc_call_callback_ptr(void);
void* temporalio_perl_bridge_ephemeral_server_start_callback_ptr(void);
void* temporalio_perl_bridge_ephemeral_server_shutdown_callback_ptr(void);
```

**Queue entry struct (in the generated header):**

```c
typedef struct TemporalioPerlBridgeEntry {
    uint64_t callback_id;
    uint8_t kind;  /* tagged union discriminator */
    /* Common: */
    const struct TemporalCoreByteArray* success_ba;
    const struct TemporalCoreByteArray* fail_ba;
    /* Client connect / ephemeral server start may also carry a pointer: */
    void* success_handle;
    /* RPC call carries additional fields: */
    uint32_t rpc_status_code;
    const struct TemporalCoreByteArray* rpc_failure_details;
    /* Ephemeral server start target: */
    const struct TemporalCoreByteArray* ephemeral_target;
} TemporalioPerlBridgeEntry;
```

`kind` discriminates between the six callback shapes (1..6 matching the
trampoline list above).

**Behavior:**

- Queue is implemented as `crossbeam_queue::SegQueue<Entry>` plus an `AtomicI32`
  holding the signal fd.
- Each trampoline: pushes one entry, then writes a `u64` `1` to the eventfd
  (or one byte to the pipe write-end) — coalescing-safe because the Perl
  drain loop drains until empty.
- `queue_drain` is non-blocking: it pops up to `out_buf_capacity` entries and
  returns the count. It also drains the eventfd / pipe so subsequent writes
  signal again.
- Queue is unbounded. (Worst-case backpressure is the sdk-core poller's own
  bounds.)
- One queue allocation per `Temporalio::Core::Runtime` instance. Trampolines
  find the right queue through the `user_data` pair allocated by
  `temporalio_perl_bridge_user_data_new($queue, $callback_id)`; the pair is
  freed by the trampoline after enqueueing (single-shot). This makes
  multi-runtime support sound: each pending call routes its completion to
  its own runtime's queue and fd.
- **Log forwarding is out of scope for the v0.1 shim.** The upstream
  `TemporalCoreForwardedLogCallback` fires on Rust threads and the log
  record is freed as soon as the callback returns (header contract), so
  forwarding requires a seventh trampoline that deep-copies the record
  before enqueueing. Deferred past v0.1 (§15).

**Failure modes:**

- Queue allocation failure (OOM) → unrecoverable, process aborts.
- `signal_fd` write fails (pipe broken, peer closed) → log and drop the
  signal; the entry remains in the queue and will be drained on the next
  successful signal. This avoids leaking work but is recoverable on transient
  errors.

**Test scenarios (Rust-side, `cargo test`):**

- T-shim-1: Push 1000 entries from 8 Tokio threads concurrently, drain from
  main thread, verify all 1000 arrive in some order with no duplicates.
- T-shim-2: eventfd is written exactly once per push if the signal succeeds;
  if the signal write returns EAGAIN it's not retried (drainer will pick up
  the backlog).
- T-shim-3: After `queue_free`, no entries remain; subsequent pushes are UB
  and not tested (caller must not push after free — Perl side enforces).
- T-shim-4: Pipe fallback (when `signal_fd` is a pipe write-end, not an
  eventfd) — same semantics; verified by feature-gating in test.

**Dependencies:** `temporalio-sdk-core-c-bridge`, `crossbeam-queue`, `libc`,
`cbindgen` (build).

---

## 4. Core layer — `Temporalio::Core::*`

### 4.1 `Temporalio::Core::FFI`

**Purpose:** Hold the `FFI::Platypus` instance and attach every C ABI function
the SDK needs from `sdk-core-c-bridge` and `temporalio-perl-bridge`.

**File:** `sdk/lib/Temporalio/Core/FFI.pm`

**Behavior:**

- At `use` time, creates one process-wide `FFI::Platypus` (api => 2) loaded
  with both `Alien::Temporalio::Core->dynamic_libs` and the
  `temporalio-perl-bridge` shared library (loaded via Alien path resolution
  or a sibling Alien dist).
- Declares opaque types for every C struct: `TemporalCoreRuntime`,
  `TemporalCoreConnection`, `TemporalCoreWorker`,
  `TemporalCoreCancellationToken`, `TemporalCoreByteArray`,
  `TemporalCoreEphemeralServer`, `TemporalioPerlBridgeQueue`.
- Declares record types for every passed-by-value struct used:
  `TemporalCoreByteArrayRef`, `TemporalCoreConnectionOptions`,
  `TemporalCoreRuntimeOptions`, `TemporalCoreTelemetryOptions`,
  `TemporalCoreLoggingOptions`, `TemporalCoreMetricsOptions`,
  `TemporalCoreOpenTelemetryOptions`, `TemporalCorePrometheusOptions`,
  `TemporalCoreClientTlsOptions`, `TemporalCoreClientRetryOptions`,
  `TemporalCoreClientKeepAliveOptions`, `TemporalCoreRpcCallOptions`,
  `TemporalCoreWorkerOptions`, `TemporalCoreDevServerOptions`.
- Attaches the full set of functions enumerated in
  `temporal-sdk-core-c-bridge.h` plus the trampoline pointer accessors from
  `temporalio-perl-bridge`.
- Exposes wrapper subs renamed to drop the `temporal_core_` /
  `temporalio_perl_bridge_` prefix and convert to snake_case where needed
  (already snake_case in the header).

**Failure modes:**

- Library load fails → `die` with the path attempted and OS error.
- A function fails to attach (signature mismatch) → `die` at module load. We
  fail loudly so version skew is detected at import time, not at first call.

**Test scenarios:**

- T-ffi-1: `use Temporalio::Core::FFI;` succeeds; all expected wrapper subs
  are present in the symbol table.
- T-ffi-2: Each opaque type round-trips through a known-no-op function (we
  use `temporal_core_runtime_new` / `_free` as the canonical round-trip).
- T-ffi-3: With a deliberately-renamed library on disk, load fails with the
  expected diagnostic.

**Dependencies:** `FFI::Platypus`, `Alien::Temporalio::Core`,
`Alien::Temporalio::PerlBridge`.

### 4.2 `Temporalio::Core::Runtime`

**Purpose:** Lifecycle wrapper around `TemporalCoreRuntime`, exposed as
`Temporalio::Runtime` (public re-export). Owns telemetry config, callback
queue, eventfd.

**Files:** `sdk/lib/Temporalio/Runtime.pm`,
`sdk/lib/Temporalio/Runtime/TelemetryConfig.pm`,
`sdk/lib/Temporalio/Runtime/LoggingConfig.pm`,
`sdk/lib/Temporalio/Runtime/LoggingFilter.pm`,
`sdk/lib/Temporalio/Runtime/OpenTelemetryConfig.pm`,
`sdk/lib/Temporalio/Runtime/PrometheusConfig.pm`.

**Public API:**

```perl
my $rt = Temporalio::Runtime->new(
    telemetry                 => Temporalio::Runtime::TelemetryConfig->new(...),
    worker_heartbeat_interval => 60,   # seconds; default 60
);

my $default = Temporalio::Runtime->default;       # lazy create
Temporalio::Runtime->set_default($rt, error_if_already_set => 1);

$rt->shutdown;       # idempotent; flushes telemetry; frees C runtime
```

**Telemetry config classes:**

```perl
Temporalio::Runtime::TelemetryConfig->new(
    logging            => Temporalio::Runtime::LoggingConfig->new(...),  # default LoggingConfig->default
    metrics            => undef                                          # OR one of:
        | Temporalio::Runtime::OpenTelemetryConfig->new(...)
        | Temporalio::Runtime::PrometheusConfig->new(...),
        # NOTE: no MetricBuffer — the C bridge has no buffered-metrics API
        # (that is a Python-bridge-only feature). Custom metric meters via
        # TemporalCoreCustomMetricMeter callbacks are deferred (§15).
    global_tags        => { region => 'us-west-2' },
    attach_service_name => 1,
    metric_prefix      => undef,
);

Temporalio::Runtime::LoggingConfig->new(
    filter     => Temporalio::Runtime::LoggingFilter->new(
                    core_level  => 'INFO',
                    other_level => 'WARN',
                ),                                  # OR a raw filter string
    # Log forwarding to a Perl logger is deferred past v0.1 (§15): the
    # upstream forward callback fires on Rust threads and frees the record
    # on return, so it needs a dedicated deep-copy trampoline (§3).
);

Temporalio::Runtime::OpenTelemetryConfig->new(
    url                       => 'http://otel:4317',
    headers                   => { authorization => 'Bearer ...' },
    metric_periodicity        => 60,                # seconds
    metric_temporality        => 'cumulative',      # or 'delta'
    durations_as_seconds      => 0,
    protocol                  => 'grpc',            # or 'http'
    histogram_bucket_overrides => { my_metric => [0.1, 0.5, 1, 5, 10] },
);

Temporalio::Runtime::PrometheusConfig->new(
    bind_address           => '0.0.0.0:9464',
    counters_total_suffix  => 0,
    unit_suffix            => 0,
    durations_as_seconds   => 0,
    histogram_bucket_overrides => { ... },
);
```

**Behavior:**

- `->new` builds the C-side `TemporalCoreRuntimeOptions` and calls
  `temporal_core_runtime_new`; checks `RuntimeOrFail.fail` and raises
  `Temporalio::Exception::Runtime` with the message if non-null.
- Creates a new `temporalio-perl-bridge` callback queue plus a wake-up
  fd: on Linux, `Linux::FD::Event->new(0, 'nonblock')` (eventfd from
  CPAN, maintained by LEONT); on non-Linux (macOS, BSD), a `pipe(2)`
  pair with `O_NONBLOCK`. The choice is hidden inside
  `Temporalio::Core::Callback` — the rest of the SDK only sees an
  `IO::Async::Handle`-compatible read end.
- Registers the wake-up fd's read end with `IO::Async::Loop->loop_any`
  for the default runtime (lazy) or with a caller-provided
  `IO::Async::Loop` for constructed-by-user runtimes.
- `Temporalio::Runtime->default` is lazy and idempotent (`our $_DEFAULT`).
- `set_default($rt, error_if_already_set => 1)` raises
  `Temporalio::Exception::Runtime` with message
  `"Default runtime already set"` if `$_DEFAULT` is non-null and
  `error_if_already_set` is true. Passing `error_if_already_set => 0`
  unconditionally replaces (and shuts down the previous default).
- `->shutdown`:
  1. Unregisters the eventfd from the loop.
  2. Calls `temporalio_perl_bridge_queue_free` on the queue.
  3. Calls `temporal_core_runtime_free` on the runtime ptr.
  4. Clears `$_DEFAULT` if this was the default.
  5. Sets an internal `$_shutdown` flag; subsequent operations raise.
  6. Idempotent — second call is a no-op.
- `DESTROY` calls `->shutdown` if not already shut down. Logs a warning
  via `warn` because relying on `DESTROY` is fragile in Perl. Tests must
  call `->shutdown` explicitly.

**Failure modes:**

- C runtime construction fails → `Temporalio::Exception::Runtime` raised
  from `->new`.
- Telemetry config has both `metrics => $otel` and `metrics => $prom` (only
  one allowed) → `Temporalio::Exception::Argument` raised from
  `TelemetryConfig->new`.
- `set_default` race when `error_if_already_set => 1` → raise.
- Use after `->shutdown` → `Temporalio::Exception::Runtime`
  `"Runtime is shut down"`.

**Test scenarios:**

- T-rt-1: `Temporalio::Runtime->new` with defaults succeeds; `dynamic_libs`
  resolves; queue is allocated.
- T-rt-2: `Temporalio::Runtime->default` returns the same instance on
  repeated calls.
- T-rt-3: `set_default` errors on second call by default; succeeds with
  `error_if_already_set => 0`.
- T-rt-4: `TelemetryConfig` with both OTel and Prometheus raises
  `Argument`.
- T-rt-5: After `->shutdown`, any client/worker construction against the
  runtime raises `Runtime is shut down`.
- T-rt-6: Log filter string is constructed correctly from
  `LoggingFilter->new(core_level => 'INFO', other_level => 'WARN')` —
  asserts the produced filter string equals `"WARN,temporalio_sdk_core=INFO,..."`
  matching the format other SDKs produce.
- T-rt-7: (removed — log forwarding deferred past v0.1, §15.)
- T-rt-8: (removed — the C bridge has no buffered-metrics API; MetricBuffer
  was a Python-bridge-only feature and is not part of this SDK.)

### 4.3 `Temporalio::Core::ByteArray`

**Purpose:** Wrap `*const TemporalCoreByteArray` returned from the bridge,
own the free path, expose Perl-scalar access.

**File:** `sdk/lib/Temporalio/Core/ByteArray.pm`

**Public API (internal):**

```perl
my $ba = Temporalio::Core::ByteArray->wrap($ptr, $runtime);
my $bytes = $ba->bytes;       # copies into a Perl scalar
my $sv    = $ba->to_string;   # alias to ->bytes
$ba->free;                    # explicit; idempotent
# DESTROY also calls ->free
```

**Behavior:**

- `->wrap($ptr, $runtime)` blesses a hashref holding the pointer and a weak
  reference to the runtime (to find the runtime ptr for the
  `temporal_core_byte_array_free` call).
- `->bytes` reads `data` + `size` fields from the underlying struct via
  `FFI::Platypus::Buffer::buffer_to_scalar`. Lazily caches the scalar.
- `->free` calls `temporal_core_byte_array_free(runtime_ptr, ba_ptr)` and
  marks freed. Subsequent calls are no-ops.
- `->bytes` after `->free` raises `Temporalio::Exception::Runtime`
  `"ByteArray freed"`.
- `DESTROY` calls `->free`.

**Failure modes:**

- Runtime weak reference dead (runtime shut down before byte array freed) →
  warn and skip free; mark freed. (Process would have leaked the
  byte-array memory but the runtime is gone anyway.)

**Test scenarios:**

- T-ba-1: Round-trip: a runtime + a hand-crafted byte array with known
  contents → `->bytes` returns the same contents.
- T-ba-2: After `->free`, `->bytes` raises.
- T-ba-3: `DESTROY` invokes the free path (verified via mock that counts
  free calls).
- T-ba-4: Multiple `->free` calls are idempotent.

### 4.4 `Temporalio::Cancellation`

**Purpose:** Wrap `TemporalCoreCancellationToken` for client-side
cancellation of long-running RPCs and worker-side cancellation propagation.

**File:** `sdk/lib/Temporalio/Cancellation.pm`

**Public API:**

```perl
my $token = Temporalio::Cancellation->new;
$token->cancel;
my $is_cancelled = $token->is_cancelled;
my $f = $token->cancelled;      # Future that resolves when cancelled
```

**Behavior:**

- `->new` calls `temporal_core_cancellation_token_new`; stores pointer.
- `->cancel` calls `temporal_core_cancellation_token_cancel`; sets a
  Perl-side `$cancelled` field; resolves the `cancelled` Future.
- `->is_cancelled` returns the Perl-side flag (cheap; no FFI).
- `->cancelled` returns a `Future` that resolves on cancel. If already
  cancelled at call time, returns an already-resolved Future.
- `DESTROY` calls `temporal_core_cancellation_token_free`.

**Failure modes:**

- None (all ops are infallible after construction).

**Test scenarios:**

- T-can-1: New token → `is_cancelled` false; `cancelled` Future pending.
- T-can-2: `cancel` → `is_cancelled` true; pending `cancelled` resolves;
  subsequent `cancelled` returns already-resolved.
- T-can-3: Multiple `cancel` calls are idempotent.

### 4.5 `Temporalio::Core::Callback`

**Purpose:** Bridge between FFI callback completion and Perl-side Future
resolution. Drains the `temporalio-perl-bridge` queue when the eventfd reads
ready and resolves the corresponding pending Future.

**File:** `sdk/lib/Temporalio/Core/Callback.pm`

**Public API (internal):**

```perl
my $f = Temporalio::Core::Callback->issue_async(
    $runtime,
    $callback_kind,          # 'worker_poll' | 'worker' | 'connect' | 'rpc' | ...
    $invoke,                 # coderef ($user_data, $callback_fn_ptr) -> void
);
my $result = await $f;
```

**Behavior:**

- Allocates a monotonic 64-bit `$callback_id` (process-wide).
- Creates a new `Future` from the runtime's loop.
- Records `{ id => $id, kind => $kind, future => $f }` in the runtime's
  pending-callbacks hash.
- Allocates the C-side pair via
  `temporalio_perl_bridge_user_data_new($runtime->queue_ptr, $callback_id)`.
- Calls `$invoke->($user_data, $callback_fn_ptr)` where
  `$callback_fn_ptr` is the appropriate trampoline pointer fetched from
  `temporalio_perl_bridge_<kind>_callback_ptr` (cached at module load).
  The trampoline frees the pair after enqueueing — Perl never frees it.
- Returns the Future.

**Drain loop (runs when eventfd ready):**

1. Call `temporalio_perl_bridge_queue_drain($queue, $buf, $cap)` for
   `$cap = 256` per iteration; loop until drain returns 0.
2. For each entry:
   - Look up pending Future by `callback_id`.
   - Construct result based on `kind`:
     - `worker_poll`: `(success_ba, fail_ba)` — null/null = shutdown
       (resolve Future with `undef`); fail_ba present = `done` with a
       `Temporalio::Exception::Bridge` constructed from fail_ba; success_ba
       present = `done` with the raw bytes scalar.
     - `worker`: `fail_ba` — null = success (resolve with undef); non-null
       = fail with `Temporalio::Exception::Bridge`.
     - `connect`: `success_handle` (connection ptr) or `fail_ba`.
     - `rpc`: see RPC error mapping table in §6.5.
     - etc.
   - Resolve or reject the Future.
   - Free the byte arrays via `Temporalio::Core::ByteArray->wrap(...)->free`
     once consumed.
3. Remove the entry from pending-callbacks hash.

**Failure modes:**

- Callback ID not in pending hash (would be a bridge bug) → log a warning,
  free the byte arrays, drop. Don't crash the worker loop.

**Test scenarios:**

- T-cb-1: `issue_async` returns a pending Future. Manually push a result
  into the queue (via direct FFI call to a trampoline), signal the fd,
  drive the loop, assert the Future resolves with the expected bytes.
- T-cb-2: 1000 concurrent `issue_async` calls each with a unique queue
  push; assert all 1000 Futures resolve.
- T-cb-3: Stale callback id (push without corresponding pending entry) is
  logged and dropped, not panicked.
- T-cb-4: Drain limit honors `cap` and loops until empty.

### 4.6 `Temporalio::Core::Proto`

**Purpose:** Load all vendored `.proto` files once at startup via
`Protobuf::Parser` (the pure-Perl `Protobuf` distribution —
<https://github.com/MasonEgger/protobuf-perl>), generate Perl message
classes under the `Temporalio::Proto::*` namespace via
`Protobuf::Class::Generator`, and provide encode/decode helpers.

**File:** `sdk/lib/Temporalio/Core/Proto.pm`

**Vendored protos (under `sdk/share/proto/`):**

Vendor the **complete** proto trees from the pinned sdk-rust tag — not a
trimmed subset:

```
temporal/api/**        # full api_upstream tree
                       #   (sdk-rust crates/protos/protos/api_upstream/temporal/api/)
temporal/sdk/core/**   # full local tree
                       #   (sdk-rust crates/protos/protos/local/temporal/sdk/core/,
                       #    including core_interface.proto at the root)
google/**              # any non-WKT google deps shipped in api_upstream
```

Rationale: `temporal/api/workflowservice/v1/request_response.proto`
transitively imports `command/v1`, `query/v1`, `update/v1`, `protocol/v1`,
`sdk/v1`, `version/v1`, `batch/v1`, `namespace/v1`, `schedule/v1`,
`nexus/v1`, `deployment/v1`, and more; the coresdk protos import
`temporal/sdk/core/nexus/`. A hand-trimmed list breaks on the first
re-vendor. The `google.protobuf` well-known types are NOT vendored — the
`Protobuf` distribution bundles them in its own sharedir and
`Protobuf::Parser` auto-resolves them (`include_wkt` defaults to 1).

**Public API (internal — but used everywhere):**

```perl
Temporalio::Core::Proto->load;            # idempotent; called at module init

# Constructed message (generated classes take a hashref):
my $msg = Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation->new({ ... });
my $bytes = $msg->encode;
my $msg2  = Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation->decode($bytes);

# Field access (generated accessors):
$msg->run_id;             # reader
$msg->set_run_id('r1');   # chainable setter
$msg->jobs;               # repeated → arrayref
$msg->to_hashref;         # plain-hash view
```

**Behavior:**

- At module init:
  1. Construct one
     `Protobuf::Parser->new(include_paths => [$share_proto_root])`
     (bundled WKTs auto-included).
  2. Call `->parse_with_imports($rel)` on the root files (every
     `temporal/api/workflowservice/v1/*.proto` and every coresdk root);
     each call returns a resolved `Protobuf::Schema`; diamond imports are
     de-duplicated by the parser's abs-path cache.
  3. For every message in the schemas, call
     `Protobuf::Class::Generator->build(message => $m, schema => $schema,
     target_package => $pkg)` with the mechanical package mapping
     (proto package → CamelCase `::` path under `Temporalio::Proto::`):
     - `temporal.api.common.v1` → `Temporalio::Proto::Api::Common::V1`
     - `temporal.api.failure.v1` → `Temporalio::Proto::Api::Failure::V1`
     - `temporal.api.workflowservice.v1` → `Temporalio::Proto::Api::Workflowservice::V1`
     - `coresdk.workflow_activation` → `Temporalio::Proto::Coresdk::WorkflowActivation`
     - etc.
- `->load` is idempotent — subsequent calls no-op.
- Provides `Temporalio::Core::Proto::resolve($protobuf_full_name)` →
  returns the generated Perl class name (thin wrapper over the generator's
  full-name → package registry), e.g. for use by the Failure converter.
- The `json/protobuf` payload encoding (§5.2) goes through `Protobuf::JSON`
  against the same schema.

**Failure modes:**

- A `.proto` fails to load (syntax error, missing import) → die at module
  init with the offending file path. (The original Phase 0 proto risk
  spike is CLOSED — protobuf-perl parses the complete Temporal proto
  graph; see §11 Phase 0 and `proto3-perl/verification-2026-06-09.md`.
  This failure mode remains specified to catch re-vendor regressions.)

**Test scenarios:**

- T-proto-1: `Temporalio::Core::Proto->load` succeeds.
- T-proto-2: Round-trip a `WorkflowActivation` message: construct via
  Perl class, encode, decode, assert structural equivalence.
- T-proto-3: Round-trip a `StartWorkflowExecutionRequest` (deepest
  realistic import chain — regression guard for re-vendored protos).
- T-proto-4: Failure proto with a non-trivial cause chain (3 deep) round-trips.
- T-proto-5: `resolve('temporal.api.failure.v1.Failure')` returns
  `'Temporalio::Proto::Api::Failure::V1::Failure'`.

**Dependencies:** `Protobuf` (protobuf-perl; installed from
`git+https://github.com/MasonEgger/protobuf-perl.git` until it reaches
CPAN), vendored `.proto` files in `share/proto/`. No `protoc`, no
`libprotobuf` system dependency.

---

## 5. Data conversion — `Temporalio::Converter::*`

### 5.1 `Temporalio::Converter::Data`

**Purpose:** Top-level facade combining payload converter, failure
converter, and an ordered list of payload codecs. The single object passed
to client and worker.

**File:** `sdk/lib/Temporalio/Converter/Data.pm`

**Public API:**

```perl
my $dc = Temporalio::Converter::Data->new(
    payload_converter => $pc,      # default: Temporalio::Converter::Payload->default
    failure_converter => $fc,      # default: Temporalio::Converter::Failure->default
    payload_codecs    => [ ... ],  # default []
);

my @payloads = await $dc->to_payloads(\@values);
my @values   = await $dc->from_payloads(\@payloads, \@type_hints);   # type_hints optional
my $failure  = await $dc->to_failure($exception);
my $exception = await $dc->from_failure($failure);
```

**Behavior:**

- `to_payloads`: for each value, call `payload_converter->to_payload($value)`
  producing a `Payload`. Then apply payload codecs in order (each codec's
  `->encode($payloads)` transforms the list). Return the final list.
- `from_payloads`: apply payload codecs in **reverse** order (each codec's
  `->decode($payloads)`). Then for each payload call
  `payload_converter->from_payload($payload, $type_hint)`. Return the values.
- `to_failure`: pass through to `failure_converter`. Then if any payload
  codecs are configured, encode the `Failure`'s embedded payloads using the
  same codec chain.
- `from_failure`: decode embedded payloads via codec chain reverse, then
  pass to `failure_converter`.
- Codec order matters and is part of the Temporal spec — encode in order,
  decode in reverse. Documented loudly.

**Failure modes:**

- Codec `->encode` raises → propagate as
  `Temporalio::Exception::DataConverter` wrapping the cause.
- Payload converter fails on a value → same.

**Test scenarios:**

- T-conv-1: With no codecs and JSON converter, round-trip a hashref.
- T-conv-2: With a single XOR codec, encode→decode round-trips.
- T-conv-3: With two codecs A, B: encode applies A then B; decode applies
  B then A. Verified by codec mocks that record the call order.
- T-conv-4: Failure with a codec-wrapped payload round-trips.

### 5.2 `Temporalio::Converter::Payload`

**Purpose:** Abstract base + default composite implementation.

**File:** `sdk/lib/Temporalio/Converter/Payload.pm`

**Public API:**

```perl
# Abstract base — subclasses implement these:
method to_payload ($value) { ... }              # returns Payload or undef if not handled
method from_payload ($payload, $type_hint = undef) { ... }   # returns value or dies if not handled
method encoding { ... }                          # returns encoding string

# Default composite:
my $pc = Temporalio::Converter::Payload->default;
# composes: BinaryNull, BinaryPlain, JsonProtobuf, BinaryProtobuf, Json
# in that order — Temporal spec order.
```

**Encoding strings (Temporal-spec, MUST match):**

- `'binary/null'`
- `'binary/plain'`
- `'json/plain'`
- `'json/protobuf'`
- `'binary/protobuf'`

**Subclasses (one per encoding) — all in `sdk/lib/Temporalio/Converter/Payload/`:**

- `BinaryNull`: handles `undef`. Encoding `binary/null`. Data empty.
- `BinaryPlain`: handles raw bytes (strings without UTF-8 flag set, or
  objects with `->isa('Temporalio::Payload::RawBytes')`). Encoding `binary/plain`.
- `JsonProtobuf`: handles generated `Temporalio::Proto::*` message
  instances (detected via the `Protobuf::Class::Generator` registry /
  `$value->can('descriptor')`) serialized through `Protobuf::JSON`.
  Encoding `json/protobuf`. Metadata `messageType` set to the full proto
  type name from `$value->descriptor->full_name`.
- `BinaryProtobuf`: same but binary form (`$value->encode`). Encoding
  `binary/protobuf`.
  Selected when the value is wrapped in a `Temporalio::Payload::BinaryProto`
  hint.
- `Json`: catch-all via `JSON::PP` with `canonical => 1, allow_blessed => 0`.
  Encoding `json/plain`. Default for hashrefs, arrayrefs, plain scalars
  that aren't bytes.

**Composite behavior:**

- `to_payload`: try each in order; first to return defined Payload wins.
- `from_payload`: dispatch on `payload->metadata->{encoding}` to the matching
  subclass.

**Failure modes:**

- No converter handled the value → `Temporalio::Exception::DataConverter`
  with the value's ref type in the message.
- `from_payload` with an unknown encoding → same.

**Test scenarios:**

- T-pay-1: `undef` → BinaryNull → `undef`.
- T-pay-2: plain hashref `{ a => 1 }` → Json → `{ a => 1 }`.
- T-pay-3: A generated `Temporalio::Proto::*` message instance →
  JsonProtobuf → same instance (structurally).
- T-pay-4: Unknown blessed object without `to_payload` support →
  `Exception::DataConverter` with the class name in the message.
- T-pay-5: Custom subclass plugged into a composite — verifies it's tried
  first when registered first.

### 5.3 `Temporalio::Converter::Failure`

**Purpose:** Convert between `Temporalio::Exception::*` instances and
`temporal.api.failure.v1.Failure` proto messages, preserving the `cause`
chain in both directions.

**File:** `sdk/lib/Temporalio/Converter/Failure.pm`

**Public API:**

```perl
my $failure = $fc->to_failure($exception, $payload_converter);
my $exception = $fc->from_failure($failure, $payload_converter);
```

**Failure proto info-type mapping (Temporal spec, MUST match):**

| Failure info type | Perl exception class |
|---|---|
| `application_failure_info` | `Temporalio::Exception::Application` |
| `timeout_failure_info` | `Temporalio::Exception::Timeout` |
| `canceled_failure_info` | `Temporalio::Exception::Cancelled` |
| `terminated_failure_info` | `Temporalio::Exception::Terminated` |
| `server_failure_info` | `Temporalio::Exception::Server` |
| `reset_workflow_failure_info` | `Temporalio::Exception::ResetWorkflow` |
| `activity_failure_info` | `Temporalio::Exception::Activity` |
| `child_workflow_execution_failure_info` | `Temporalio::Exception::ChildWorkflow` |
| `nexus_handler_failure_info` | `Temporalio::Exception::NexusHandler` |
| `nexus_operation_execution_failure_info` | `Temporalio::Exception::NexusOperation` |

**Behavior:**

- `to_failure($e)`:
  1. Dispatch on `$e->isa(...)` to build the right `*_failure_info` variant.
  2. Set `message` from `$e->message`.
  3. Set `stack_trace` from `$e->stack_trace` if present.
  4. Set `application_failure_info.type` from `$e->type`, `non_retryable`
     from `$e->non_retryable`, `details` by encoding `$e->details` via the
     payload converter.
  5. Recursively encode `$e->cause` as `failure.cause`.
- `from_failure($f)`:
  1. Determine which `*_failure_info` is set.
  2. Construct the matching exception class with fields from the info.
  3. Recursively decode `$f->cause` and set `cause` on the exception.

**Test scenarios:**

- T-fail-1: `ApplicationError->new(type => 'X', non_retryable => 1,
  details => ['a', 1])` → encode → decode → equivalent.
- T-fail-2: A 3-deep cause chain (Application → Activity → Application)
  round-trips.
- T-fail-3: Unknown `*_failure_info` (forward compat) → falls back to a
  generic `Temporalio::Exception::Application` with the message preserved,
  warns once.
- T-fail-4: A non-Temporal exception (plain string `die`) →
  `Application` with type `Temporalio::Exception::Plain`.

### 5.4 `Temporalio::Converter::PayloadCodec`

**Purpose:** Abstract base for payload codecs (encryption, compression).

**File:** `sdk/lib/Temporalio/Converter/PayloadCodec.pm`

**Public API:**

```perl
package My::Codec;
use feature 'class';

class My::Codec :isa(Temporalio::Converter::PayloadCodec) {
    async method encode ($payloads) { ... }   # arrayref → arrayref
    async method decode ($payloads) { ... }   # arrayref → arrayref
}
```

**Behavior:**

- Codecs are stacked via `Temporalio::Converter::Data->new(payload_codecs => [...])`.
- Spec-mandated ordering: encode in list order (first codec runs first on
  encode), decode in reverse (last codec runs first on decode).
- Codecs typically produce a new `Payload` with `metadata.encoding` set to
  their wrapper encoding (e.g. `binary/encrypted`) and the original
  payload's bytes inside `data`. Decoders unwrap accordingly.

---

## 6. Exception hierarchy — `Temporalio::Exception::*`

### 6.1 Base class

**File:** `sdk/lib/Temporalio/Exception.pm`

**Public API:**

```perl
class Temporalio::Exception {
    field $message :param;
    field $stack_trace :param = undef;
    field $cause :param = undef;

    method throw (%fields) {                  # class method
        die $class->new(%fields);
    }

    method message :reader;
    method stack_trace :reader;
    method cause :reader;
}
```

**Behavior:**

- Stringification overloaded to return `$message` + cause chain if present.
- `->throw(%fields)` constructs and `die`s.
- `cause` accessor returns the inner exception or undef.
- Caller catches via `eval { ... }` or `try { ... } catch { ... }` (use
  `Syntax::Keyword::Try` for the `try`/`catch` syntax in modern Perl).

### 6.2 Concrete subclasses (one file each in `sdk/lib/Temporalio/Exception/`)

- `Application`: fields `type`, `non_retryable`, `details` (arrayref of
  decoded payload values), `category` (default `'application'`).
- `Cancelled`: field `details`.
- `Timeout`: fields `timeout_type` (`'start_to_close'`, `'schedule_to_start'`,
  etc., matching Temporal spec strings), `last_heartbeat_details`.
- `Terminated`: field `reason`.
- `Server`: fields `non_retryable`, `details`.
- `Activity`: fields `activity_id`, `activity_type`, `attempt`, `identity`,
  `retry_state` (Temporal spec enum string), `started_event_id`,
  `scheduled_event_id`.
- `ChildWorkflow`: fields `namespace`, `workflow_id`, `run_id`,
  `workflow_type`, `retry_state`, `initiated_event_id`, `started_event_id`.
- `NexusHandler`, `NexusOperation`: fields per spec.
- `ResetWorkflow`: field `last_heartbeat_details`.
- `WorkflowAlreadyStarted`: fields `workflow_id`, `workflow_type`, `run_id`.
- `WorkflowFailure`: top-level workflow failure (wraps cause). Field
  `cause` (always present).
- `RpcError`: gRPC layer. Fields `status_code` (numeric), `status_name`
  (string per gRPC), `details` (decoded `google.rpc.Status` if present).
- `RpcTimeout`: subclass of `RpcError` for deadline-exceeded.
- `RpcUnauthenticated`: subclass.
- `RpcPermissionDenied`: subclass.
- `RpcResourceExhausted`: subclass.
- `Bridge`: low-level FFI/bridge error.
- `Runtime`: runtime lifecycle errors.
- `Argument`: invalid argument to a Perl method.
- `NotFound`: `WorkflowNotFound`, `ActivityNotFound`, `NamespaceNotFound`
  subclasses.
- `DataConverter`: payload conversion failures.
- `Heartbeat`: from `heartbeat()` call when the bridge reports a problem.
- `QueryRejected`: query rejected by `reject_condition`; field `status`
  (workflow execution status string).
- `WorkflowContinuedAsNew`: raised by `result(follow_runs => 0)` when the
  run continued-as-new; field `new_run_id`.
- `Workflow::NoRunner`: a `Temporalio::Workflow::*` function was called
  outside a workflow body.

**Test scenarios:**

- T-exc-1: `Application->new(type => 'X', non_retryable => 1)` →
  `->type` returns `'X'`, `->non_retryable` returns 1.
- T-exc-2: `Application->throw(...)` raises catchable via `eval`.
- T-exc-3: Stringification of nested causes: `"foo: caused by: bar:
  caused by: baz"`.
- T-exc-4: `isa` chain — `RpcTimeout->isa('Temporalio::Exception::RpcError')`
  is true.

---

## 7. Client — `Temporalio::Client` + `Temporalio::Client::WorkflowHandle`

### 7.1 Public connect API

**File:** `sdk/lib/Temporalio/Client.pm`

```perl
my $client = await Temporalio::Client->connect(
    'localhost:7233',                        # positional, required
    namespace      => 'default',
    api_key        => $token,                # rotate via $client->update_api_key($new)
    tls            => 1
                       | { ca_cert => $path_or_pem,
                           client_cert => $path_or_pem,
                           client_key  => $path_or_pem,
                           server_name => 'temporal.cloud' }
                       | Temporalio::Client::TlsConfig->new(...),
    identity       => "$$\@$hostname",       # default: "<pid>@<hostname>" (matches Python)
    rpc_metadata   => { 'x-extra' => 'foo' },
    retry          => { ... } | Temporalio::Client::RetryConfig->new(...),
    keep_alive     => { interval => 30, timeout => 15 },
    data_converter => $converter,
    runtime        => $rt,                   # default Temporalio::Runtime->default
    lazy           => 0,
);
```

### 7.2 `TlsConfig`, `RetryConfig`, `KeepAliveConfig`

**Files:** `sdk/lib/Temporalio/Client/TlsConfig.pm`, etc.

`TlsConfig`:
- `ca_cert`: PEM content (scalar starting with `-----BEGIN`) OR filesystem
  path (anything else with `-r`); detected automatically.
- `client_cert`, `client_key`: same.
- `server_name`: scalar.

`RetryConfig` (defaults exactly match sdk-core's `ClientRetryOptions::default`):
- `initial_interval` = 0.1 (seconds)
- `randomization_factor` = 0.2
- `multiplier` = 1.5
- `max_interval` = 5.0 (seconds)
- `max_elapsed_time` = 10.0 (seconds; 0 = unlimited)
- `max_retries` = 10

`KeepAliveConfig`:
- `interval` = 30 (seconds)
- `timeout` = 15 (seconds)

### 7.3 `connect` behavior

1. Resolves `runtime` (use default if not provided).
2. Builds `TemporalCoreConnectionOptions` from kwargs:
   - PEM material is detected; if path, slurped synchronously before the
     async call.
   - `api_key`: scalar token. Rotation is manual and explicit —
     `$client->update_api_key($new_token)` calls
     `temporal_core_client_update_api_key`. No automatic refresh timer
     and no refresh-on-UNAUTHENTICATED (no other SDK does either; the
     earlier coderef-with-refresh-timer design was an invention and is
     dropped under the prime directive).
   - `identity`: defaults to `"$$\@$hostname"` (`<pid>@<hostname>`,
     matching Python) if not provided.
3. Calls `temporal_core_client_connect` via the callback bridge.
4. On success: returns a `Temporalio::Client` instance holding the
   `TemporalCoreConnection` ptr, namespace, data_converter, identity,
   runtime, and the api_key refresher (if any).
5. On failure (fail byte array non-null): raises a
   `Temporalio::Exception::RpcError` (or subclass) with the decoded message.

### 7.4 Workflow operations

**`start_workflow`:**

```perl
my $handle = await $client->start_workflow(
    $workflow_or_string,           # class name OR a workflow function ref
    \@args,                        # arrayref of args
    id                       => 'wf-1',           # required
    task_queue               => 'demo',           # required
    execution_timeout        => 3600,             # seconds; default undef (server default)
    run_timeout              => 600,              # seconds
    task_timeout             => 10,               # seconds
    id_reuse_policy          => 'allow_duplicate', # spec strings; lowercase snake_case
                                                   # 'allow_duplicate', 'allow_duplicate_failed_only',
                                                   # 'reject_duplicate', 'terminate_if_running'
    id_conflict_policy       => 'unspecified',     # 'unspecified', 'fail', 'use_existing',
                                                   # 'terminate_existing'
    retry_policy             => Temporalio::Common::RetryPolicy->new(
        initial_interval         => 1,
        backoff_coefficient      => 2.0,
        maximum_interval         => 100,
        maximum_attempts         => 5,
        non_retryable_error_types => [ 'BadInput' ],
    ),
    cron_schedule            => '0 * * * *',       # spec format
    memo                     => { foo => 'bar' },
    search_attributes        => $typed_sa,   # TypedSearchAttributes — see below
    headers                  => { 'x-trace-id' => '...' },
    static_summary           => 'Greets a user',
    static_details           => 'Long detail body',
    priority                 => Temporalio::Common::Priority->new(priority_key => 1),
    start_delay              => 60,                # seconds
    request_eager_start      => 0,
    versioning_override      => undef,
);
```

Returns a `Temporalio::Client::WorkflowHandle` with `workflow_id`,
`run_id` (first run id), `first_execution_run_id` populated.

**Search attribute encoding (de facto spec — MUST match):** every search
attribute value is encoded as a payload carrying a `metadata.type` field
with the server SA type (`Keyword`, `Text`, `Int`, `Double`, `Bool`,
`Datetime`, `KeywordList`), mirroring Python's typed search attributes.
v0.1 accepts only typed input:

```perl
search_attributes => Temporalio::Common::TypedSearchAttributes->new([
    [ Temporalio::Common::SearchAttributeKey->keyword('CustomKeywordField') => 'x' ],
    [ Temporalio::Common::SearchAttributeKey->int('CustomIntField')         => 42 ],
]),
```

A bare untyped hashref raises `Exception::Argument` — no silent type
guessing.

**`execute_workflow`** — convenience: `start_workflow(...)` then `await
$handle->result`. Same kwargs.

**`get_workflow_handle($workflow_id, run_id => $rid, first_execution_run_id => $rid)`** —
returns a handle without an RPC.

**`signal_with_start_workflow`** — accepts same args as `start_workflow`
plus `signal => $name, signal_args => \@args`.

**`list_workflows($query, page_size => 100)`** — returns an async iterator
yielding `Temporalio::Client::WorkflowExecution` records page-by-page.

**`count_workflows($query)`** — returns `{ count => N, groups => [...] }`.

**`update_api_key($new_token)`** — sets the bearer token on the live
connection via `temporal_core_client_update_api_key`. Synchronous, no RPC.

**Other client methods:** `list_schedules`, `create_schedule`, etc., are
deferred to phase 6+.

### 7.5 RPC error → exception mapping (Temporal spec, MUST match)

Implemented in `Temporalio::Core::Callback` rpc-handler branch. Lookup
table:

| gRPC status code | gRPC name | Perl class |
|---|---|---|
| 0 | OK | (success) |
| 1 | CANCELLED | `Temporalio::Exception::Cancelled` |
| 4 | DEADLINE_EXCEEDED | `Temporalio::Exception::RpcTimeout` |
| 5 | NOT_FOUND (special-cased on workflow ops) | `Temporalio::Exception::NotFound::Workflow` or `Activity` or `Namespace` |
| 6 | ALREADY_EXISTS (special-cased on start_workflow) | `Temporalio::Exception::WorkflowAlreadyStarted` |
| 7 | PERMISSION_DENIED | `Temporalio::Exception::RpcPermissionDenied` |
| 8 | RESOURCE_EXHAUSTED | `Temporalio::Exception::RpcResourceExhausted` |
| 9 | FAILED_PRECONDITION (special-cased on query-rejected) | `Temporalio::Exception::QueryRejected` or `RpcError` |
| 14 | UNAVAILABLE | `Temporalio::Exception::RpcError` with `status_name => 'unavailable'` |
| 16 | UNAUTHENTICATED | `Temporalio::Exception::RpcUnauthenticated` |
| (any other) | various | `Temporalio::Exception::RpcError` with the full status name |

Retries are performed by sdk-core, not the Perl layer: every high-level
client method sets `retry => true` in `TemporalCoreRpcCallOptions`, and
core applies the client `RetryConfig` to the retryable codes
(`UNAVAILABLE`, `RESOURCE_EXHAUSTED`). There is no automatic api-key
refresh on `UNAUTHENTICATED` (no SDK does this). Codes that survive core's
retry policy raise the mapped exception immediately.

### 7.6 `WorkflowHandle`

**File:** `sdk/lib/Temporalio/Client/WorkflowHandle.pm`

```perl
class Temporalio::Client::WorkflowHandle {
    field $client                  :param;
    field $workflow_id             :param;
    field $run_id                  :param = undef;
    field $first_execution_run_id  :param = undef;
    field $result_run_id           :param = undef;

    async method result (
        follow_runs   => 1,
        rpc_metadata  => {},
        rpc_timeout   => undef,
    ) { ... }

    async method signal ($name_or_handler, $args = [], rpc_metadata => {}) { ... }
    async method query  ($name_or_handler, $args = [],
                         reject_condition => undef,
                         rpc_metadata => {},
                         rpc_timeout => undef) { ... }
    async method execute_update (...) { ... }   # deferred to phase 6
    async method start_update   (...) { ... }   # deferred to phase 6
    async method describe (rpc_metadata => {}, rpc_timeout => undef) { ... }
    async method cancel   (reason => undef, rpc_metadata => {}, rpc_timeout => undef) { ... }
    async method terminate(reason => undef, details => [], rpc_metadata => {}, rpc_timeout => undef) { ... }
    method fetch_history_events (
        wait_new_event => 0,
        event_filter_type => 'all_event',
        skip_archival => 0,
    ) { ... }   # returns async iterator
}
```

**`result` behavior (Temporal spec — MUST match):**

1. Repeatedly call `GetWorkflowExecutionHistory(wait_new_event=true,
   skip_archival=true, history_event_filter_type=CLOSE_EVENT)` with the
   current run id.
2. The last event is one of:
   - `WorkflowExecutionCompleted` → decode `result.payloads[0]` via
     data converter; return the value.
   - `WorkflowExecutionFailed` → decode `failure` proto, raise as
     `Temporalio::Exception::WorkflowFailure` with `cause` chain.
   - `WorkflowExecutionTimedOut` → raise `WorkflowFailure` with cause
     `Timeout`.
   - `WorkflowExecutionCanceled` → raise `WorkflowFailure` with cause
     `Cancelled`.
   - `WorkflowExecutionTerminated` → raise `WorkflowFailure` with cause
     `Terminated`.
   - `WorkflowExecutionContinuedAsNew` → if `follow_runs`, set current
     run id to `new_execution_run_id` and loop; if not, raise
     `Temporalio::Exception::WorkflowContinuedAsNew { new_run_id }`.
3. Transient gRPC errors retry transparently (UNAVAILABLE,
   RESOURCE_EXHAUSTED, DEADLINE_EXCEEDED).

**Test scenarios:**

- T-cli-connect-1: Connect to ephemeral dev server, assert returned client
  has expected namespace + identity.
- T-cli-connect-2: Connect with TLS pointing at the dev server (which
  doesn't accept TLS) — assert `Exception::RpcError` with informative
  message.
- T-cli-connect-3: Bad PEM (invalid base64) — `Exception::Argument` at
  `connect` call time (before issuing the RPC).
- T-cli-connect-4: api_key rotation — connect with token A, call
  `$client->update_api_key('B')`, assert the bridge received the update
  (mock/spy on the FFI call).
- T-cli-start-1: `start_workflow` with all required args returns a handle
  with populated `workflow_id` and `run_id`.
- T-cli-start-2: `start_workflow` with `id_reuse_policy => 'reject_duplicate'`
  twice → second raises `WorkflowAlreadyStarted`.
- T-cli-start-3: Each `id_reuse_policy` value reaches the proto correctly
  (assert via dev server's RPC log or an RPC interceptor).
- T-cli-start-4: Invalid `id_reuse_policy` string → `Exception::Argument`
  before the RPC.
- T-cli-result-1: A workflow that completes returns the decoded result.
- T-cli-result-2: A workflow that fails with `ApplicationError` raises
  `WorkflowFailure` with `cause` an `Application` with the right `type`.
- T-cli-result-3: A workflow that times out raises `WorkflowFailure` with
  `cause` a `Timeout`.
- T-cli-result-4: A workflow that calls continue-as-new and the new run
  completes — `result` with `follow_runs => 1` returns the final value;
  with `follow_runs => 0` raises `WorkflowContinuedAsNew`.
- T-cli-result-5: Long-poll transient `UNAVAILABLE` is retried; final
  resolve still succeeds.
- T-cli-signal-1: `$handle->signal('greet', ['hi'])` succeeds against a
  worker that processes it.
- T-cli-query-1: `$handle->query('status')` returns the decoded value.
- T-cli-query-2: A query that the workflow rejected → `QueryRejected`.
- T-cli-describe-1: After start, `describe` returns a record with
  populated `workflow_execution_info` fields.
- T-cli-cancel-1: `cancel` returns; `describe` shows cancel requested.
- T-cli-terminate-1: `terminate('reason')` returns; `result` raises
  `WorkflowFailure` with cause `Terminated` and reason preserved.
- T-cli-list-1: After starting 3 workflows, `list_workflows('WorkflowType=X')`
  iterates them.
- T-cli-history-1: `fetch_history_events` yields all events up to the
  current point; `wait_new_event => 1` blocks until new events arrive.

---

## 8. Worker — `Temporalio::Worker`

### 8.1 Construction

**File:** `sdk/lib/Temporalio/Worker.pm`

```perl
my $worker = Temporalio::Worker->new(
    client                            => $client,
    task_queue                        => 'demo',
    workflows                         => [ 'My::Workflow::Greeting', ... ],
    activities                        => [ 'My::Activity::SayHello',
                                           Temporalio::Activity::FunctionDefinition->new(
                                               name => 'send_email',
                                               code => async sub ($to, $subj, $body) { ... },
                                           ),
                                         ],
    build_id                          => 'my-build-2026.05',   # → versioning_strategy None{build_id}
    identity_override                 => undef,
    max_cached_workflows              => 1000,
    max_concurrent_workflow_tasks     => 100,
    max_concurrent_activities         => 100,
    max_concurrent_local_activities   => 100,
    sync_activity_workers             => 4,                    # IO::Async::Function pool size
    activity_executor                 => undef,                # advanced: custom pool
    sticky_queue_schedule_to_start_timeout => 10,
    max_heartbeat_throttle_interval   => 60,
    default_heartbeat_throttle_interval => 30,
    max_activities_per_second         => undef,
    max_task_queue_activities_per_second => undef,
    graceful_shutdown_period          => 0,
    workflow_failure_exception_types  => [ 'Some::Class' ],    # types causing workflow fail
    nondeterminism_as_workflow_fail   => 0,                    # default: continue
    interceptors                      => [],
    debug_mode                        => 0,                    # disables some optimizations
);

await $worker->run;            # blocks until shutdown
await $worker->shutdown;       # explicit shutdown
```

**Mapping to `TemporalCoreWorkerOptions` (the pinned header is
authoritative):** the C struct is richer than the kwargs above and the FFI
layer must fill all of it:

- `versioning_strategy` is a tagged union; v0.1 always passes
  `None { build_id }`. Deployment-based and legacy-build-id versioning are
  Phase 6+.
- `tuner` is a `TemporalCoreTunerHolder` of four `TemporalCoreSlotSupplier`
  unions; v0.1 always passes `FixedSize` suppliers built from
  `max_concurrent_workflow_tasks`, `max_concurrent_activities`,
  `max_concurrent_local_activities`, and a fixed `100` for the nexus slot
  supplier. Resource-based and custom slot suppliers are Phase 6+.
- `task_types` enables workflows + remote activities; local activities and
  nexus are disabled in v0.1.
- The three `*_task_poller_behavior` fields are `simple_maximum => 5`
  (core's default); autoscaling pollers are Phase 6+.
  `nonsticky_to_sticky_poll_ratio` = 0.2.
- `plugins` and `storage_drivers` are empty arrays.

Marshalling this struct — nested tagged unions passed **by value** — is
**Phase 0 risk spike 3** (§11).

### 8.2 `run` behavior

1. Builds `TemporalCoreWorkerOptions` and calls
   `temporal_core_worker_new`. Raises on failure.
2. Calls `temporal_core_worker_validate` via the callback bridge and awaits
   it; a non-null fail raises the decoded error **before any polling
   starts** (mirrors Ruby's pre-poll validate).
3. Spawns two concurrent Future tasks (on the client's runtime loop):
   - Workflow poll loop (§8.3).
   - Activity poll loop (§8.4).
4. Awaits any task completing or `shutdown` being called.
5. On shutdown signal:
   - Calls `temporal_core_worker_initiate_shutdown` (sync).
   - Waits for in-flight activities up to `graceful_shutdown_period`.
   - Calls `temporal_core_worker_finalize_shutdown` (async).
   - Frees the worker.

### 8.3 Workflow poll loop

For v0.1 (Phase 3), the loop:

1. Awaits `worker_poll_workflow_activation`.
2. On `undef` (shutdown): exits.
3. Decodes activation bytes into a `WorkflowActivation` proto.
4. **Eviction fast path:** if the activation's only job is
   `remove_from_cache`, drop the run's `Workflow::Runner` (if cached) and
   send an **empty successful completion** without invoking any workflow
   code (mirrors Ruby). Loop.
5. Applies the configured payload codecs (**decode**, reverse order) to
   every payload embedded in the activation — worker boundary, mirroring
   Python's `decode_activation`. The runner never sees encoded payloads.
6. Routes by `run_id` to the workflow dispatcher (§10), which finds or
   creates a `Workflow::Runner` for that run.
7. Calls `dispatcher->process_activation($runner, $activation)` — this is
   synchronous from the loop's perspective; the runner processes all jobs
   and produces a completion.
8. Applies payload codecs (**encode**, in order) to every payload embedded
   in the completion.
9. Awaits `worker_complete_workflow_activation($completion_bytes)`.
10. Loops.

**Deliberate v0.1 simplification:** workflow activations are processed
serially — one at a time, globally. Python and Ruby process activations
concurrently across runs (sdk-core already serializes per run). This
sacrifices workflow-task throughput, not correctness; revisit when
`max_concurrent_workflow_tasks` should be honored for real. Documented so
nobody mistakes it for a semantic constraint.

### 8.4 Activity poll loop

1. Awaits `worker_poll_activity_task`.
2. On `undef`: exits.
3. Decodes task bytes into `ActivityTask` and branches on the variant —
   `ActivityTask` is a `start | cancel` union:
   - **`cancel`** — look up the running activity by `task_token` in the
     worker's running-activities map, record the cancellation
     reason/details on its context, and `->cancel` its
     `Temporalio::Cancellation` token. No completion is sent for the
     cancel task itself; the running activity finishes (cancelled or not)
     and reports via its own completion. Unknown task token → log + drop.
     Loop.
   - **`start`** — continue.
4. Applies payload codecs (**decode**) to `start.input` and
   `start.heartbeat_details` (worker boundary).
5. Routes by `activity_type` to a registered activity; records the running
   activity in a `task_token`-keyed map (used by step 3's cancel routing;
   removed at completion).
6. Dispatches:
   - Activity declared async (`async method run :Defn` or `async sub`) →
     spawns a Perl Future on the main loop running the activity body
     with a fresh `Activity::Context`.
   - Activity declared sync (plain sub or `method run :Defn` without
     `async`) → dispatches to `Activity::Pool` (§9.3).
7. On activity completion, build an `ActivityTaskCompletion` (task_token +
   result/failure payloads, codec-**encoded**) and call
   `worker_complete_activity_task`. Remove the entry from the
   running-activities map.

### 8.5 Activity registration

`activities => [ ... ]` accepts:

- Class names (strings) of classes inheriting `Temporalio::Activity::Definition`
  with at least one `:Defn` method.
- Class instances (an already-constructed object) — multiple activities
  can share state this way.
- `Temporalio::Activity::FunctionDefinition` instances (§9.2 — the single
  function-activity API; there is no `activity_defn` sugar, per §16 #9).

The worker builds a registry keyed on activity type name → callable.
Duplicate activity type names → `Exception::Argument`.

### 8.6 Workflow registration

`workflows => [ ... ]` accepts class names inheriting
`Temporalio::Workflow::Definition` with exactly one `:Run` method. Workflow
type defaults to the class name; can be overridden via `:Run('CustomName')`.
Duplicate workflow type names → `Exception::Argument`.

### 8.7 Test scenarios

- T-wkr-1: `Worker->new` with workflows and activities succeeds; registry
  populated correctly.
- T-wkr-2: Two activities with the same type name → `Exception::Argument`.
- T-wkr-3: Worker with no workflows and one activity runs and processes
  activity tasks (gated by a workflow run by an external SDK).
- T-wkr-4: `shutdown` mid-run causes `run` to return; second `shutdown`
  is no-op.
- T-wkr-5: Worker against a non-existent task queue runs without error;
  no tasks dispatched.
- T-wkr-6: Activity slot tuning (`max_concurrent_activities = 1`) limits
  concurrency — verified by a 2-activity test where the second blocks
  until the first completes.

---

## 9. Activity — `Temporalio::Activity::*`

### 9.1 Class-based activity definition

**File:** `sdk/lib/Temporalio/Activity/Definition.pm` (base class)

```perl
package My::Activity::SayHello;
use feature 'class';
use Future::AsyncAwait;
use Temporalio::Activity;

class My::Activity::SayHello :isa(Temporalio::Activity::Definition) {
    async method run :Defn ($name) {
        my $ctx = Temporalio::Activity::context();
        $ctx->heartbeat("greeting $name");
        return "Hello, $name!";
    }
}
```

The `:Defn` attribute:

- `:Defn` — activity type = method name (or class basename if method is
  `run`).
- `:Defn('CustomType')` — explicit type name.
- `:Defn(name=CustomType,no_thread_cancellation=1)` — kwargs.

Registered at class-load via `Attribute::Handlers` into the class's
`%_TEMPORALIO_DEFS` hash. `Temporalio::Activity::Definition` exposes
`_activity_defs` class method returning the hash. The four constraints
documented in §10.1 — base-must-be-class, handler-in-inheritance-chain,
`:ATTR(CODE,BEGIN)`, arrayref-or-undef `$data` — apply identically here.

### 9.2 Function-based activity definition

There is **one** way to register a function-based activity — the class-style
constructor. No module-level sugar helper. (Per §16 #9, two APIs for the
same concept causes documentation and maintenance debt that's not worth it.)

```perl
use Temporalio::Activity::FunctionDefinition;

my $sender = Temporalio::Activity::FunctionDefinition->new(
    name => 'send_email',
    code => async sub ($to, $subject, $body) {
        my $ctx = Temporalio::Activity::context();
        ...
    },
    no_thread_cancellation => 0,
);
```

The returned object is passed in `Worker->new(activities => [...])` just
like a class-based activity.

### 9.3 Activity context — `Temporalio::Activity::Context`

**File:** `sdk/lib/Temporalio/Activity/Context.pm`

```perl
my $ctx = Temporalio::Activity::context();      # dynamically-scoped; only valid inside an activity body

$ctx->info;                  # ActivityInfo: activity_id, activity_type, attempt,
                             # workflow_id, workflow_run_id, etc. (spec list)
$ctx->heartbeat(@details);
$ctx->cancellation;          # Temporalio::Cancellation — fires when activity cancelled
$ctx->logger;                # Log::Any logger with activity context bound
$ctx->client;                # back-reference to the worker's client
$ctx->payload_converter;
```

`heartbeat(@details)` converts details via the payload converter, applies
the codec chain (encode), wraps them in a
`coresdk.ActivityHeartbeat { task_token, details }` proto
(`core_interface.proto`), and makes the synchronous FFI call
`worker_record_activity_heartbeat`. A non-null returned byte array raises
`Temporalio::Exception::Heartbeat`. (Throttling is core's job — the worker
options' heartbeat-throttle intervals — not the Perl layer's.)

`context()` lookup is via a dynamically-scoped variable. **Critical
caveat:** Perl's built-in `local` is unsafe across an `await` point in
`Future::AsyncAwait` and will panic at the await with
`Future::AsyncAwait panic: TODO: Unsure how to handle a savestack entry
of SAVEt_SV with gv != PL_errgv`. The activity dispatcher MUST use
`Syntax::Keyword::Dynamically` (same author as F::AA; explicitly designed
for this case):

```perl
use Syntax::Keyword::Dynamically;
{
    dynamically $Temporalio::Activity::Context::CURRENT = $ctx;
    await $activity_body->($args);
}
```

`Syntax::Keyword::Dynamically` is a hard dependency of the SDK.

For sync activities (running in a forked child via `IO::Async::Function`),
the context is recreated on the child side from a serialized minimal
struct sent via the pipe. `heartbeat()` in the child sends a pipe message
back to the parent which then calls the sync FFI heartbeat.

### 9.4 Activity pool (sync dispatch)

**File:** `sdk/lib/Temporalio/Activity/Pool.pm`

```perl
class Temporalio::Activity::Pool {
    field $loop :param;
    field $max_workers :param = 4;
    field $function;

    ADJUST {
        $function = IO::Async::Function->new(
            min_workers => 0,
            max_workers => $max_workers,
            code        => \&_child_main,
        );
        $loop->add($function);
    }

    async method invoke ($activity_invocation) {
        return await $function->call(args => [ $activity_invocation ]);
    }

    method close { $function->stop }
}
```

`IO::Async::Function` exposes two callbacks per fork: `init_code` runs
**once** per child process at fork time, before any invocation; `code`
runs **per invocation**. The activity pool wires them:

```perl
ADJUST {
    $function = IO::Async::Function->new(
        min_workers => 0,
        max_workers => $max_workers,
        init_code   => sub {
            # Runs exactly once in each forked child, before the first
            # activity body. Close inherited FDs so the child does not
            # accidentally drain the parent's eventfd, callback queue,
            # or open client sockets.
            POSIX::close($_) for @inherited_fds_to_close;
            # Load the activity registry into the child's interpreter.
            require_module($_) for @activity_modules;
        },
        code => \&_child_dispatch,
    );
    $loop->add($function);
}
```

`_child_dispatch` is per-invocation:

1. Decodes the activity_invocation (activity type name, args as
   JSON-encoded Perl scalars, context info).
2. Looks up the activity callable in the child's registry (populated by
   `init_code`).
3. Sets up a `Temporalio::Activity::Context` with a heartbeat callback
   that writes to a pipe back to the parent.
4. Runs the body.
5. Returns the result (or throws).

The parent worker forwards heartbeats from the child pipe to the FFI
sync heartbeat call.

### 9.5 Test scenarios

- T-act-1: `My::Activity::SayHello` class — `_activity_defs` returns
  `{ 'SayHello' => $methodref }` after class load.
- T-act-2: `:Defn('Custom')` overrides the registered name.
- T-act-3: Two `:Defn` methods on one class → both registered with their
  respective names.
- T-act-4: `Temporalio::Activity::FunctionDefinition->new(name => ...,
  code => ...)` registers a function activity.
- T-act-5: Async activity body completes; result reaches the worker;
  activity completion sent.
- T-act-6: Sync activity body in fork pool completes; result reaches the
  worker.
- T-act-7: Activity body calls `heartbeat('progress')` — verified to
  reach `record_activity_heartbeat`.
- T-act-8: Activity throws `ApplicationError->throw(type => 'X')` —
  activity task completion contains the failure; cause type is `'X'`.
- T-act-9: Activity respects cancellation — `await $ctx->cancellation`
  resolves when worker signals cancel; activity returns CancelledError.
- T-act-10: Sync activity in fork pool — child closes parent FDs.
  Verified by attempting to read the parent's eventfd from the child
  (must fail with EBADF).

---

## 10. Workflow — `Temporalio::Workflow::*`

### 10.1 Definition surface

**Files:** `sdk/lib/Temporalio/Workflow/Definition.pm`,
`sdk/lib/Temporalio/Workflow/Attributes.pm`.

```perl
package My::Workflow::Greeting;
use feature 'class';
use Future::AsyncAwait;
use Temporalio::Workflow;

class My::Workflow::Greeting :isa(Temporalio::Workflow::Definition) {
    field $greeting = 'Hello';

    async method run :Run ($name) {
        my $reply = await Temporalio::Workflow::execute_activity(
            'My::Activity::SayHello',
            args => [ $name ],
            start_to_close_timeout => 60,
        );
        return $reply;
    }

    method change_greeting :Signal('changeGreeting') ($new) {
        $greeting = $new;
    }

    method current_greeting :Query ($) {
        return $greeting;
    }
}
```

Attribute syntax (handled via `Attribute::Handlers`):

- `:Run` — exactly one per class. Workflow type defaults to the class
  basename (e.g., `Greeting`); overridden via `:Run('CustomName')`.
- `:Signal` — signal name defaults to method name; `:Signal('foo')` or
  `:Signal(name=foo)` overrides; `:Signal(dynamic=1)` for dynamic.
- `:Query` — same shape.
- `:Update` — same shape. Optional `:UpdateValidator('updateName')` paired.
- `:Init` — method runs in workflow context just before `:Run` to perform
  one-time initialization (mirrors Python's `workflow.init`).

**Four constraints empirically verified against Perl 5.38.2 — see
`t/spike/` for runnable proofs:**

1. **`Temporalio::Workflow::Definition` must itself be declared with `class`**,
   not as a plain package. A plain-package base produces
   `Class :isa attribute requires a class but "..." is not one`.
2. **All `:ATTR` handlers must live in the inheritance chain** —
   specifically inside `Temporalio::Workflow::Definition`. Importing
   `Attribute::Handlers` into a subclass from outside the base fails with
   `Invalid CODE attribute: Signal(...)`.
3. **Handlers must use `:ATTR(CODE,BEGIN)`, not the default `CHECK`.**
   Workers `require` user workflow modules at runtime; by then the global
   CHECK pass has already completed and `CHECK`-phase handlers silently
   never fire. `BEGIN` runs at the loaded module's compile time
   regardless of when `require` happens — the right phase for an SDK whose
   users register workflows dynamically.
4. **`$data` in the `:ATTR` callback arrives as `ARRAYREF or undef`,
   never a bare string.** `:Signal('greet')` produces `['greet']`; bare
   `:Signal` produces `undef`. The registry builder normalises via
   `ref($data) eq 'ARRAY' ? $data->[0] : undef`.

**Registration:** `Attribute::Handlers` populates per-class
`%_TEMPORALIO_DEFS` with `{ run => $methodref, signals => { name => $mref },
queries => {...}, updates => {...}, validators => {...}, init => $mref }`.
`Temporalio::Workflow::Definition` exposes `_workflow_defs` class method.
Both `$ref->($instance, @args)` and `$instance->$ref(@args)` are valid
ways to invoke a captured method-ref — the worker uses the
`$instance->$ref(@args)` form for consistency.

**Workflow type override (class-wide):** `class
:isa(Temporalio::Workflow::Definition) :WorkflowName('CustomWorkflow')`
— class-level attribute. Last-resort override; usually unnecessary.

### 10.2 Workflow context (module-level functions)

**File:** `sdk/lib/Temporalio/Workflow.pm` (functional surface)

All functions in `Temporalio::Workflow::` namespace look up the active
runner via `$Temporalio::Workflow::Runner::CURRENT`, which is dynamically
scoped by the runner during workflow body execution using
`Syntax::Keyword::Dynamically` (see §9.3 — `local` is unsafe across
`await` in Future::AsyncAwait). The runner wraps every workflow-body call
in `dynamically $Temporalio::Workflow::Runner::CURRENT = $self;`. Calling
any of these functions outside a workflow body raises
`Temporalio::Exception::Workflow::NoRunner`.

```perl
my $f = Temporalio::Workflow::execute_activity(
    $activity_type | $class | $function_def,
    args                  => \@args,
    task_queue            => undef,                # default: workflow's queue
    schedule_to_close_timeout => undef,
    schedule_to_start_timeout => undef,
    start_to_close_timeout    => 60,
    heartbeat_timeout         => undef,
    retry_policy              => Temporalio::Common::RetryPolicy->new(...),
    activity_id               => undef,            # default: spec-generated
    cancellation_type         => 'try_cancel',     # 'try_cancel', 'wait_cancellation_completed', 'abandon'
    versioning_intent         => undef,
    summary                   => undef,
    priority                  => undef,
    headers                   => {},
);

my $f = Temporalio::Workflow::execute_local_activity(...);   # same shape — Phase 6+ (§15)
my $f = Temporalio::Workflow::start_activity(...);           # returns handle, not Future of result

my $f = Temporalio::Workflow::start_timer($seconds, summary => 'wait');
my $f = Temporalio::Workflow::sleep($seconds);

my $f = Temporalio::Workflow::wait_condition(
    sub { ... predicate ... },
    timeout => 300,
    timeout_summary => '...',
);

# Time and randomness (must be deterministic — these are the only legal sources):
my $datetime = Temporalio::Workflow::now;          # DateTime from activation timestamp
my $epoch    = Temporalio::Workflow::time;         # epoch seconds
my $rng      = Temporalio::Workflow::random;       # returns a Math::Random::ISAAC-like object seeded deterministically
my $log      = Temporalio::Workflow::logger;       # Log::Any logger; suppresses output during replay
my $info     = Temporalio::Workflow::info;         # WorkflowInfo: workflow_id, run_id, workflow_type, attempt,
                                                   # task_queue, namespace, etc.
my $memo     = Temporalio::Workflow::memo;
my $sa       = Temporalio::Workflow::search_attributes;
my $is_repl  = Temporalio::Workflow::is_replaying;

Temporalio::Workflow::upsert_search_attributes($attrs);
Temporalio::Workflow::upsert_memo($memo);

Temporalio::Workflow::continue_as_new(
    $workflow_or_string,
    args              => \@args,
    task_queue        => undef,
    workflow_id_reuse_policy => undef,
    retry_policy      => undef,
    memo              => undef,
    search_attributes => undef,
    headers           => {},
    versioning_intent => undef,
);

# Child workflows (Phase 6+ — deferred past v0.1 per §15):
my $f = Temporalio::Workflow::execute_child_workflow($workflow, args => [...], id => '...');
my $h = Temporalio::Workflow::start_child_workflow($workflow, args => [...], id => '...');

# Versioning (patching — implemented in v0.1; see §10.5):
my $v = Temporalio::Workflow::patched('my-change');
Temporalio::Workflow::deprecate_patch('old-change');
```

### 10.3 Workflow runner

**File:** `sdk/lib/Temporalio/Workflow/Runner.pm`

One instance per workflow run. Owns:

- A reference to the workflow Definition instance (constructed once per run,
  via `$class->new(@args)` for the first activation containing a
  `StartWorkflow` job; cached for subsequent activations on the same run id).
- A pending-Futures map: `{ seq => $future }` for activities and timers
  (child workflows join this map in Phase 6+).
- Sequence counter: monotonically incremented at command emission.
- Outbound command buffer: `[ { schedule_activity => {...} }, ... ]`.
- The run's "running" Future (returned by the `:Run` method's invocation).
- The current activation context: timestamp, `is_replaying` flag, run id.
- Signal queue: for signals delivered before/during `:Run` startup.

**Activation processing (`process_activation($activation)`):**

1. Set `is_replaying` from the activation.
2. Set the activation timestamp as the runner's "now".
3. **Order the jobs before applying them** (de facto spec — mirrors
   Python's four ordered sets): (a) patch notifications, (b) signals and
   updates, (c) all other non-query jobs, (d) queries last. Within each
   set, preserve activation order.
4. Process jobs. For each job:
   - `InitializeWorkflow / StartWorkflow { args, randomness_seed, ... }` —
     seed the deterministic RNG from the job's `randomness_seed` field,
     instantiate the class, set
     `$_TEMPORALIO_RUN_FUTURE = $instance->run(@args)` (returns a Future).
     The Future is not awaited synchronously; it will be polled via the
     pump phase.
   - `FireTimer { seq }` — resolve `pending_timers{seq}` with undef.
   - `ResolveActivity { seq, result }` — resolve `pending_activities{seq}`
     with the decoded result, OR reject with the failure mapped to a
     `Temporalio::Exception::Activity`.
   - `SignalWorkflow { name, input }` — look up the signal handler in
     `_workflow_defs->{signals}`, call it; if no handler matches and a
     dynamic handler is registered, call that; else queue the signal
     into `pending_signals` for later (dynamic registration is allowed
     mid-run). Signal handlers may be `async` — the returned Future is
     tracked in the runner's in-progress-handlers set and pumped like any
     other workflow Future (mirrors Python's tracked handler tasks).
   - `QueryWorkflow { id, query_type, args }` — synchronous (a query
     handler must not await); look up the query handler, call it, push a
     `RespondToQuery` command with the result OR a failure if the handler
     `die`d.
   - `CancelWorkflow` — set the run's cancellation flag, cancel the
     main run Future.
   - `RemoveFromCache { reason }` — **eviction.** Tear the runner down:
     cancel all pending Futures, drop the instance from the dispatcher's
     run_id map, and respond with an **empty successful completion**. No
     workflow code runs. (Usually the only job in its activation — see
     the §8.3 fast path; if it ever arrives combined with other jobs,
     eviction is applied last.)
   - `NotifyHasPatch { patch_id }` — record in workflow info.
   - `UpdateRandomSeed { seed }` — re-seed the deterministic RNG.
   - `ResolveChildWorkflowExecutionStart` / `ResolveChildWorkflowExecution`
     — Phase 6+ (child workflows are deferred past v0.1).
   - (more job kinds in later phases — see Phase 6+)
5. Pump phase: drive the main run Future and all pending continuations
   until no further progress is possible.
6. Drain the command buffer into a `WorkflowActivationCompletion` proto.
   The **completion outcome** follows the de facto Temporal spec:
   - Run method returned a value → `CompleteWorkflowExecution { result }`.
   - A `Temporalio::Exception::Cancelled` escaped the run method after a
     `CancelWorkflow` job → **`CancelWorkflowExecution`** (NOT
     FailWorkflowExecution).
   - A Temporal failure exception (any `Temporalio::Exception::*` the
     failure converter maps) or an exception whose class matches the
     worker's `workflow_failure_exception_types` escaped →
     `FailWorkflowExecution { failure }` — fails the workflow execution.
   - **Any other exception** (plain `die`, internal error) → the entire
     completion is **failed** (`WorkflowActivationCompletion.failed` with
     the converted failure): a workflow *task* failure, which the server
     retries; the workflow execution does not fail.
   - `continue_as_new` → `ContinueAsNewWorkflowExecution`.
7. Return the proto to the worker for `worker_complete_workflow_activation`.

**Pump semantics:**

The pump is synchronous within `process_activation` — it drives any
Future continuations whose dependencies were satisfied by this activation's
jobs. It does NOT await on IO::Async (workflow Futures are all
`Temporalio::Workflow::Future` subclass instances resolved by the runner,
not by IO::Async timers). The pump:

```
loop {
    last unless any $f in (pending_futures + main_run_future) became
                ready since the last iteration;
    for each ready Future, run its on_ready callbacks (which are the
        continuations registered by Future::AsyncAwait await);
}
```

Once no progress can be made, the pump exits. Commands generated by those
continuations are in the command buffer.

**Sequence number allocation:**

Sequence numbers are allocated at command emission time (when
`Temporalio::Workflow::execute_activity` is called and the
`ScheduleActivity` command is pushed). They are workflow-scoped, monotonic
starting at 1. This matches Temporal spec exactly.

**`Temporalio::Workflow::Future`:**

A subclass of `Future` (the CPAN `Future` module) that adds:

- Cancellation hook registered via `Future`'s real API: `$f->on_cancel(sub
  { ... })`. The hook emits a `RequestCancelExternalWorkflowExecution` /
  `CancelActivity` / etc. command into the runner's command buffer.
  `on_cancel` callbacks fire in reverse-registration order on
  `$f->cancel`; the workflow runner relies on this for nested
  cancellation chains.
- `is_workflow_future` — true; used by interceptors to distinguish.

### 10.4 Replay safety primitives

- `Temporalio::Workflow::now` reads from
  `$Temporalio::Workflow::Runner::CURRENT->activation_time`. Never the OS
  clock.
- `Temporalio::Workflow::random` returns a `Math::Random::ISAAC::XS`
  instance seeded from the `randomness_seed` field of the activation's
  initialize/start-workflow job (NOT derived from the run id). Re-seeded
  whenever an `UpdateRandomSeed` job arrives.
- `Temporalio::Workflow::logger` returns a `Log::Any` adapter whose
  `is_*` methods always return true (so user code can build messages)
  but which discards output when
  `$Temporalio::Workflow::Runner::CURRENT->is_replaying` is true. After
  replay catches up, output resumes.
- Standard Perl `time()`, `localtime`, `rand` are NOT intercepted; user
  discipline is required. The reference docs explicitly forbid them
  inside workflow bodies. Linter/lint hint in v0.1+ (deferred).

### 10.5 Determinism / non-determinism handling

- Worker option `nondeterminism_as_workflow_fail` defaults to false.
  When false (default), a non-determinism error (replay mismatch) causes
  the workflow task to fail (which sdk-core retries). When true, the
  workflow execution itself fails with the spec-defined
  `WorkflowFailure`.
- `nondeterminism_as_workflow_fail_for_types` allows per-workflow-type
  override.

### 10.6 Replay test harness

**File:** `sdk/lib/Temporalio/Test/WorkflowReplay.pm`

```perl
my $harness = Temporalio::Test::WorkflowReplay->new(
    workflow_class => 'My::Workflow::Greeting',
);

# Push a hand-crafted activation; get back commands.
my @commands = $harness->push_activation(
    Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation->new({
        run_id => 'r1',
        timestamp => { seconds => 100 },
        jobs => [
            { start_workflow => { workflow_args => [ "Alice" ] } },
        ],
    }),
);
# @commands is the decoded list from the completion proto.

# Or load history JSON from a file (mirrors Python's WorkflowReplayer):
$harness->replay_history($history_json);
```

### 10.7 Workflow test scenarios (replay-driven; no server needed)

- T-wf-1: `My::Workflow::Greeting` with a single `:Run` — first activation
  with `StartWorkflow { args: ['Alice'] }`. Assert commands include one
  `ScheduleActivity` for `My::Activity::SayHello` with the right args.
- T-wf-2: Second activation `ResolveActivity { seq: 1, result: "Hello,
  Alice!" }` — assert commands include `CompleteWorkflowExecution { result:
  "Hello, Alice!" }`.
- T-wf-3: `:Signal` handler invoked before `:Run` returns — signal
  semantically processed first, state mutation visible to `:Run`
  continuation.
- T-wf-4: `:Query` handler invoked during a pending activity — synchronous;
  returns current state; doesn't disturb the main run Future.
- T-wf-5: `wait_condition` with predicate that becomes true on a signal —
  pump resumes the awaiting continuation only after the signal is processed.
- T-wf-6: `start_timer(60)` then activation includes a `FireTimer { seq: 1 }`
  — pump resumes; subsequent commands reflect post-sleep work.
- T-wf-7: Activity throws — `ResolveActivity { seq, failure }` — Perl
  exception raised at the `await` site, with `->cause->type` correctly
  populated.
- T-wf-8: `continue_as_new` — last command is `ContinueAsNewWorkflowExecution`
  with the right args and policies.
- T-wf-9: `is_replaying` true during replay → logger.info messages
  produce no output (verified by capturing a test logger's records).
- T-wf-10: `random` is deterministic — two runners with the same seed
  produce the same sequence.
- T-wf-11: `:Run` body completes — final command is
  `CompleteWorkflowExecution`.
- T-wf-12: Cancellation: `CancelWorkflow` job → pending activity Future
  rejected with `Cancelled` → `:Run` body's exception bubbles → final
  command is `CancelWorkflowExecution` (de facto spec — NOT
  FailWorkflowExecution).
- T-wf-13: Non-determinism: a `ResolveActivity { seq: 99 }` for an
  unknown seq → emits non-determinism workflow failure (when configured).
- T-wf-14: Eviction: an activation whose only job is `RemoveFromCache` →
  empty successful completion, runner dropped from the cache, no workflow
  code invoked; a subsequent activation for the same run id replays from
  the start.
- T-wf-15: Task failure vs workflow failure: a plain `die "boom"` in the
  run body → completion is `failed` (workflow task failure; server
  retries); an `Application` exception → `FailWorkflowExecution`; a
  non-Temporal class listed in `workflow_failure_exception_types` →
  `FailWorkflowExecution`.

---

## 11. Phase acceptance criteria

Aggregated from the phased roadmap + specific test IDs above.

### Phase 0 — skeleton + risk spikes

- Monorepo layout created (alien/, sdk/, ext/).
- Dist::Zilla configs in alien/ and sdk/.
- `Alien-Temporalio-Core` builds the bridge cdylib from
  `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH` local override. T-alien-1, T-alien-3.
- `temporalio-perl-bridge` shim crate compiles. cbindgen generates header.
  T-shim-1.
- `Temporalio::Core::FFI` loads both libraries, attaches at least
  `temporal_core_runtime_new` / `_free` / `temporal_core_byte_array_free`.
  T-ffi-1.
- `Temporalio::Runtime->new` + `->shutdown` works for the trivial default
  config. T-rt-1.
- **Risk spike 1 (proto loading): CLOSED — by experiment, 2026-06-09.**
  `Protobuf` (protobuf-perl) parses the complete Temporal proto graph —
  both the `api_upstream/` and `local/` roots from sdk-rust — and
  round-trips messages through all three integration paths
  (parser-direct, descriptor-set, AOT codegen). See
  `proto3-perl/verification-2026-06-09.md`. Parser-direct is the chosen
  integration (§4.6); no `protoc`, no `libprotobuf`. Phase 0 keeps
  T-proto-1..3 as regression tests against re-vendored protos, not as a
  spike.
- **Risk spike 2 (`feature 'class'` × `Attribute::Handlers`): CLOSED —
  works.** Verified empirically on Perl 5.38.2; spike artifacts preserved
  in `sdk/t/spike/attribute_handlers.t` and adjacent files. The four
  constraints from §10.1 are now permanent design requirements, not
  open questions. Phase 0 still includes a Test2-style version of this
  test to guard against regressions on newer Perl versions in CI.
- **Risk spike 3 (`TemporalCoreWorkerOptions` marshalling): CLOSED —
  hand-packed `pack()` buffer, 2026-06-11.** The struct embeds tagged
  unions passed **by value** — `TemporalCoreWorkerVersioningStrategy`,
  and four `TemporalCoreSlotSupplier` unions inside
  `TemporalCoreTunerHolder` — which `FFI::Platypus::Record` cannot
  express (no unions, no nested records), so the spec-sanctioned fallback
  is the mechanism: `Temporalio::Core::FFI::WorkerOptions` hand-packs the
  full 464-byte struct with `pack` per the pinned header's x86-64 SysV
  layout (we control the header version, so the layout is stable per
  release). Verified empirically without a server: the shim's
  `temporalio_perl_bridge_debug_worker_options` parses the Perl-built
  struct through `#[repr(C)]` mirrors of the bridge's own definitions and
  echoes every field as `field=value` lines;
  `sdk/t/unit/worker_options_marshal.t` asserts the full v0.1
  configuration (versioning `None{build_id}`, four `FixedSize` suppliers,
  simple-maximum pollers) plus a pairwise-distinct-values configuration
  match field-for-field. The original spike's live
  `temporal_core_worker_new` exercise happens at worker construction
  (Phase 2, T-wkr-1). Bumping the sdk-rust pin requires re-running the
  echo test (plan P0.10).

### Phase 1 — client smoke

- All Phase 0 + the following:
- `Temporalio::Core::Callback` eventfd queue draining works against the
  shim. T-cb-1 through T-cb-4.
- `Temporalio::Core::Proto` loads all vendored .protos. T-proto-1 through
  T-proto-5.
- `Temporalio::Client->connect` against ephemeral dev server.
  T-cli-connect-1 through T-cli-connect-4.
- `Temporalio::Client->start_workflow` returns a handle.
  T-cli-start-1, T-cli-start-2, T-cli-start-3.
- `WorkflowHandle->result` returns the result for a workflow handled by a
  reference Python or Go worker against the same ephemeral server.
  T-cli-result-1, T-cli-result-3, T-cli-result-5.
- `Temporalio::Test::DevServer` helper boots the ephemeral server in
  `BEGIN`, shuts down in `END`. Each test file gets its own namespace.

### Phase 2 — worker + activities

- All Phase 1 +:
- `Temporalio::Worker->new` and `->run`. T-wkr-1, T-wkr-2, T-wkr-4.
- Async activity registered + dispatched. T-act-1, T-act-5, T-act-7.
- Sync activity in fork pool. T-act-6, T-act-10.
- Activity heartbeats reach the bridge. T-act-7.
- Cancellation propagates from worker to activity. T-act-9.
- Integration: client starts a workflow (workflow body provided by a
  reference SDK), Perl worker provides one activity, full round-trip
  completes.

### Phase 3 — workflows

- All Phase 2 +:
- `Temporalio::Workflow::Definition` loads; `:Run` attribute registers
  the method. T-wf-1 entry.
- Workflow runner processes activations. T-wf-1 through T-wf-2.
- `execute_activity` produces the right command. T-wf-1.
- `start_timer` / `sleep` work. T-wf-6.
- `now` / `time` / `random` / `logger` deterministic. T-wf-9, T-wf-10.
- Eviction handled (`RemoveFromCache` → empty success completion + runner
  teardown). T-wf-14.
- Task failure vs workflow failure branches correct. T-wf-15.
- End-to-end: Perl workflow + Perl activity completes via the ephemeral
  dev server.

### Phase 4 — signals & queries

- All Phase 3 +:
- `:Signal` handler invoked on `SignalWorkflow` job. T-wf-3.
- `:Query` handler invoked synchronously. T-wf-4.
- `wait_condition` resumes on signal. T-wf-5.
- `WorkflowHandle->signal` and `->query` end-to-end. T-cli-signal-1,
  T-cli-query-1.

### Phase 5 — hardening

- All Phase 4 +:
- Full exception hierarchy populated, conversion round-trips.
  T-exc-1, T-fail-1, T-fail-2.
- Cancellation end-to-end: `WorkflowHandle->cancel` → workflow
  cancelled → in-flight activity cancelled. T-cli-cancel-1, T-wf-12.
- POD coverage for every public class (enforced in `xt/`).
- One full example in `examples/hello-world/` runnable via
  `perl examples/hello-world/run.pl` against a dev server.
- CI matrix green: Ubuntu 22.04 + macOS 14, Perl 5.38 + (5.40 when
  available), Rust stable.
- README with installation instructions, quickstart, link to this spec.
- `Temporalio::SDK::VERSION` = `0.1.0`.

### v0.1.0 acceptance status (2026-06-13)

**All phases P0–P5 are implemented and accepted.** The full TDD plan
(`plan.md`, steps P0.1–P5.5) is complete; `todo.md` has zero unchecked
items. The three distributions — `Alien-Temporalio-Core`,
`Alien-Temporalio-PerlBridge`, and `Temporalio-SDK` — and the Rust shim
crate (`temporalio-perl-bridge`) all declare a consistent dist version of
`0.1.0`, guarded by `sdk/t/unit/version.t`. `Alien::Temporalio::Core->version`
deliberately reports the pinned upstream sdk-core release (`0.4.0`, derived
from the alienfile `$pinned_tag`), which is tracked independently of the
Perl dist version. All three risk spikes are CLOSED (proto loading,
`feature 'class'` × `Attribute::Handlers`, `TemporalCoreWorkerOptions`
marshalling). POD coverage is enforced in `xt/`, the
`examples/hello-world/` example is runnable, and the GitHub Actions CI
matrix (spec §14) is in place. Tagging and any release to `main` are
performed manually by the maintainer; this SDK does not push to `main`.

### v0.2 — feature parity with the mature SDKs

v0.2 brings the SDK to feature parity with the Python and Ruby SDKs:
every capability they expose that v0.1 deferred, except the items still
listed in §15 (Sessions, prebuilt binaries, CPAN publication, Windows).
Each phase below is authored into a detailed contract section (§18+,
Public API + behavioral contract + failure modes + `T-*` test IDs,
mirroring the reference SDKs per §0) before its TDD plan is generated.
Target version `Temporalio::SDK::VERSION` = `0.2.0`.

#### Phase 6 — Workflow feature parity

- **Child workflows**: `Temporalio::Workflow::start_child_workflow` /
  `execute_child_workflow` emit `StartChildWorkflowExecution`; a
  `ChildWorkflowHandle` (id, first-execution run id, `signal`, result)
  resolves on `ResolveChildWorkflowExecutionStart` /
  `ResolveChildWorkflowExecution`; parent-close policy
  (TERMINATE / ABANDON / REQUEST_CANCEL), cancellation type, and
  id-reuse/conflict honored. T-child-*.
- **Workflow updates**: `:Update` + `:UpdateValidator` dispatched on the
  `DoUpdate` job (validate → accept/reject → execute, results via
  `UpdateResponse`); client `execute_update` / `start_update` +
  `UpdateHandle`; in-flight updates gate workflow completion like async
  signals. T-upd-*, T-cli-update-*.
- **External workflow handles**: `get_external_workflow_handle` →
  `signal` / `cancel` (Signal/RequestCancel ExternalWorkflowExecution).
  T-ext-*.

#### Phase 7 — Activity feature parity

- **Local activities**: `execute_local_activity` / `start_local_activity`
  in the runner (local-retry/backoff, `ScheduleLocalActivity`), executed
  on the worker's local-activity path. T-local-*.
- **Async activity completion**: an activity signals "completes
  asynchronously"; a client async-activity handle (by task token or
  ids) supports heartbeat / complete / fail / cancel out of band.
  T-async-act-*.

#### Phase 8 — Scheduling

- **Schedules**: client `create_schedule` / `list_schedules` /
  `get_schedule_handle`; `ScheduleHandle` (describe, update, delete,
  trigger, pause, unpause, backfill); schedule spec (calendar/interval),
  policy, and start-workflow action. T-sched-*.

#### Phase 9 — Nexus

- **Caller side**: `start_nexus_operation` / `execute_nexus_operation`
  from workflow code (`ScheduleNexusOperation`, `NexusOperationHandle`,
  cancellation).
- **Handler side**: Nexus service + operation definitions, operation
  handler dispatch on the worker, sync and async operations. T-nexus-*.

#### Phase 10 — Runtime, observability & worker hardening

- **core → Perl log forwarding**: the seventh deep-copy shim trampoline
  (§3); forwarded core logs surface through a Perl logger. T-log-fwd-*.
- **Custom metric meters**: `TemporalCoreCustomMetricMeter` callbacks
  bridged to a Perl meter interface (counter / histogram / gauge), in
  addition to the existing Prometheus/OTel exporters. T-meter-*.
- **Advanced worker tuning**: custom slot suppliers, autoscaling pollers,
  and deployment-based worker versioning (build IDs / worker
  deployments). T-wkr-ver-*.
- **Determinism enforcement**: detect and forbid illegal
  non-deterministic calls in workflow context (Ruby-style illegal-call
  detection; a Python-style import sandbox stays out of scope — §15).
  T-det-*.

#### v0.2 acceptance gate

- All Phase 6–10 `T-*` IDs implemented; parity matrix green in CI.
- Runnable examples for child workflows, updates, schedules, and Nexus.
- `Temporalio::SDK::VERSION` = `0.2.0` (version-agreement test updated).

---

## 12. Test infrastructure

### 12.1 Test framework

- **`Test2::V1`** everywhere (released 2025-12-09 by EXODIST,
  supersedes V0 — metacpan V1 POD: "This module is recommended over
  Test2::V0 for new tests"). Not `Test::More`.
- **Critical V1 caveat:** `Test2::V0` enabled `strict`, `warnings`, and
  `utf8` by default. **V1 does NOT.** Every test file's preamble must
  explicitly start with:
  ```perl
  use v5.38;
  use warnings;
  use utf8;
  use Test2::V1;
  ```
- `Test::Future::AsyncAwait` for asserting on Future-returning subs.
- `Test2::Plugin::DieOnFail` in `xt/` for fast-fail feedback during
  author tests.
- Each test file is self-contained — no shared state via `BEGIN`.
- `prove -lj4` is the canonical test command. `dzil test` for the full
  per-distribution check.

### 12.2 Ephemeral dev server — `Temporalio::Test::DevServer`

**File:** `sdk/lib/Temporalio/Test/DevServer.pm`

```perl
use Test2::V0;
use Temporalio::Test::DevServer;

my $server = Temporalio::Test::DevServer->start(
    download_dest_dir => undef,    # default: cache under XDG_CACHE_HOME
    log_level         => 'warn',
);

ok($server->target, 'has target host:port');
my $client = await Temporalio::Client->connect($server->target);

# At end of file (via END block or explicit):
$server->shutdown;
```

**Behavior:**

- `start` calls `temporal_core_ephemeral_server_start_dev_server` via the
  callback bridge. Awaits the start-up.
- Server runs in-process (sdk-core embeds the binary).
- One instance per test file. Random port. Random namespace prefix per
  test for isolation.
- `shutdown` calls `temporal_core_ephemeral_server_shutdown`. Idempotent.

### 12.3 Workflow replay harness — see §10.6.

---

## 13. Documentation

- POD on every public class using Dist::Zilla `[PodWeaver]` +
  `Pod::Elemental::Transformer::List` + `Pod::Weaver::Section::Authors`.
- `xt/pod-coverage.t` enforces 100% POD coverage on `Temporalio::*` public
  classes.
- README.md in repo root and in each distribution.
- `examples/hello-world/` and `examples/greet-with-signal/`.
- Per-class POD includes at least: synopsis, description, public method
  list with signature, exception list.

---

## 14. CI

GitHub Actions, defined in `.github/workflows/ci.yml` at repo root.

**Floor: Perl 5.38.0** (where `feature 'class'` landed; shipped in
Ubuntu 24.04 LTS — the dominant production Linux through 2029 — and
Alpine 3.20). Going higher than 5.38 cuts off Ubuntu 24.04 LTS without
buying any feature (roles have not merged as of 5.42; `class` is still
experimental in 5.42). Every workflow/activity/exception class file
declares `no warnings 'experimental::class';` at the top.

Matrix:

- **OS:** `ubuntu-22.04`, `ubuntu-24.04`, `macos-14` (Apple Silicon),
  `macos-13` (Intel)
- **Perl:** `5.38`, `5.40`, `5.42` (all three, all jobs)
- **Rust:** `stable` (1.80+)
- **Windows (allow-failure):** one job on `windows-2022` with
  `strawberry-perl` and `stable-x86_64-pc-windows-msvc`, marked
  `continue-on-error: true`. Surfaces obvious portability breakage early
  without blocking releases.

Stages:

1. Install Perl via `shogo82148/actions-setup-perl`.
2. Install Rust via `dtolnay/rust-toolchain@stable`.
3. Install `cpanm` + workspace deps.
4. Build `Alien::Temporalio::Core` with `ALIEN_TEMPORALIO_CORE_SDK_RUST_PATH`
   pointed at a checkout of `temporalio/sdk-rust@v0.4.0`.
5. Build `Alien::Temporalio::PerlBridge` (in-tree).
6. Run `dzil test` on `sdk/`.
7. Run `xt/pod-coverage.t`.
8. (Phase 1+) Run integration tests against ephemeral dev server.

Cache:

- `~/.cargo` for cargo dependencies.
- `~/.cpanm` for Perl dependencies.

**Documentation note:** RHEL 9 ships Perl 5.32 (frozen, EOL 2032) — too
old for the SDK. RHEL 9 users need Software Collections or perlbrew. macOS
system Perl is 5.34 and Apple has warned for years it will be removed.
README documents this.

---

## 15. Explicitly deferred

Most of the original v0.1 deferrals — updates, child workflows, async
activity completion, schedules, local activities, Nexus, log forwarding,
custom metric meters, advanced worker tuning, and determinism
enforcement — are claimed by the v0.2 feature-parity scope (§11, Phases
6–10). The following remain deferred beyond v0.2:

- **Sessions** (activity session pinning). A Go/Java-only concept; the
  Python and Ruby SDKs do not expose it, so it is outside parity scope.
- **Workflow sandbox** (Python-style import/global isolation). v0.2 does
  determinism *enforcement* (illegal-call detection, Ruby-style); a full
  import sandbox is a separate, larger effort.
- **Prebuilt binary releases per triple.** Install builds `sdk-core` and
  the shim from source; shipping precompiled per-platform libraries is a
  separate packaging workstream.
- **CPAN publication.** Install remains git-based.
- **Windows support.** Best-effort CI only; not a supported target.

---

## 16. Perl-specific decisions (resolved)

Each decision was made under the prime directive (Temporal-spec-first,
Perl-second), reviewed by a Perl-expert subagent, and a Phase 0 spike was
run for the empirically-verifiable ones. Spike artifacts preserved in
`sdk/t/spike/`.

1. **Exception classes:** hand-rolled with `feature 'class'`. Base
   `Temporalio::Exception` declares `use overload q{""} => sub { ... };`
   inside the class block — verified working in 5.38.2 (see
   `/tmp/verify_C_overload.pl` output captured in spike report).
   `->throw(%fields)` is a class method that constructs and `die`s.
   `Devel::StackTrace` (not `Carp::longmess`) for the `stack_trace`
   field — it survives object boundaries cleanly. ~30 subclasses each
   declaring their own typed fields via `field $x :param :reader`.
   ADJUST blocks validate `cause` is an exception. Rejected:
   `Throwable` (Moo role, slower construction — matters for workflow
   replay loops that may construct hundreds of exceptions),
   `Exception::Class` (1990s ergonomics, slower).

   **Hard dependency added: `Syntax::Keyword::Dynamically`.** Required
   wherever the SDK establishes per-call dynamic scope across an
   `await` point (Activity context, Workflow runner context).
   Built-in `local` panics inside a `Future::AsyncAwait` `async sub`
   when the locally-scoped SV crosses an `await` (rt.cpan.org #122793
   — F::AA POD documents the TODO). Empirically verified panicking on
   Perl 5.38.2 + F::AA 0.71; `dynamically` fixes it. Same author
   (PEVANS) as F::AA, explicitly tested cross-module.
2. **Subroutine attributes on `method`:** **work in 5.38** with four
   constraints, all empirically verified in
   `sdk/t/spike/attribute_handlers.t`:
   (a) base class must itself be declared with `class`,
   (b) `:ATTR(CODE,...)` handlers must live in the inheritance chain,
   (c) handlers use `:ATTR(CODE,BEGIN)` not `CHECK` (workers `require`
       user code at runtime; CHECK has already passed by then),
   (d) `$data` arrives as `arrayref-or-undef`, not bare string.
   The expert review's claim that this was broken was wrong. The plan's
   `:Signal('changeGreeting')` syntax stands.
3. **Test framework:** **`Test2::V1`** (released 2025-12-09;
   supersedes V0 per its own POD). Use `Test2::Plugin::DieOnFail` in
   `xt/` for fast feedback. Use `Net::EmptyPort` (Miyagawa) for
   free-port-per-file in the dev server harness. Use
   `Test2::Tools::Compare::is` with a custom comparator for protobuf
   round-trips (`->encode` gives canonical bytes — that's the right
   equality check). Skip `Test2::AsyncSubtest` — plain `subtest`
   with `await` works fine. **V1 caveat:** unlike V0, V1 does not
   auto-import `strict`/`warnings`/`utf8`; every test file declares
   them explicitly (see §12.1 for the canonical preamble).
4. **Logger interop:** mirror `Log::Any`'s real API exactly — accept any
   object with `->info($msg)`, `->infof($fmt, @args)`, and `->is_info`
   (and the same for other levels). `Log::Any` is the canonical
   recommendation; non-`Log::Any` loggers are duck-typed via
   `can('info')`. Internally, the SDK gets a logger via
   `Log::Any->get_logger(category => 'Temporalio::Worker')` etc., so
   users can filter by subsystem via `Log::Any::Adapter`'s category
   filter. Structured fields (workflow_id, run_id) pass via Log::Any's
   `proxy` mechanism — preserved as structured context, not stringified.
5. **Dev server lifecycle:** one per test file with per-test namespace
   prefixes. Boot in `BEGIN`/`state`, shutdown in `END`. Per-file port
   via `Net::EmptyPort` to allow `prove -j`. Server stderr logged to
   `t/tmp/dev-server.<pid>.log` (not `/dev/null`) so failures are
   debuggable from the server's perspective.
6. **Dist::Zilla:** three `dist.ini` files, all using
   `[@Starter::Git]` (Dan Book / Grinnz). Shared chrome
   (`[License]`, `[MetaResources]`, `[GithubMeta]`) collected into a
   PluginBundle in `inc/` if it bothers anyone; otherwise duplicated.
   Include `[Test::ReportPrereqs]` (mandatory for FFI bug reports).
   Pin DZ plugin versions in `cpanfile.devel` — plugin API churn has
   burned every Perl project that doesn't.
7. **Documentation:** hand-written POD in each `.pm`. **No `Pod::Weaver`.**
   Pod::Weaver's auto-section plugins don't compose with `feature 'class'`
   (introspection assumes `sub` definitions). Hand-written POD matches
   what Mojolicious does. Use `Pod::Readme` to auto-extract README from
   `lib/Temporalio.pm`. `[PodSyntaxTests]` in CI for podchecker.
8. **CI:** Ubuntu 22.04 + 24.04, macOS 13 (Intel) + 14 (Apple Silicon),
   all running Perl 5.38, 5.40, 5.42. One non-blocking Windows job with
   `strawberry-perl` (allow-failure) to catch obvious portability
   issues early. Apple Silicon vs Intel cross-build needs `--target`
   explicit on the Alien — tested on both.
9. **Activity function-definition:** **single API only** —
   `Temporalio::Activity::FunctionDefinition->new(name => ..., code =>
   ...)`. No `activity_defn` sugar. Two APIs for the same concept causes
   documentation and maintenance debt without payoff (Mojolicious split
   `Mojolicious::Lite` as a separate module instead of overloading the
   main one). The Python SDK's `@activity.defn` decorator desugars to a
   class transformation under the hood — the underlying object is what
   the registry consumes; mirror that conceptually.
10. **Perl version floor: 5.38.0.** That's where `feature 'class'`
    landed. 5.38 ships in Ubuntu 24.04 LTS (supported through 2029) and
    Alpine 3.20 — the production install base. Going higher cuts off
    Ubuntu 24.04 with no feature payoff: roles have **not** merged
    (5.42 perldelta is silent on roles; the expert review's claim that
    they shipped in 5.42 was wrong). `class` is still experimental
    through 5.42, so every file declaring a class includes
    `no warnings 'experimental::class';`. CI matrix tests against
    5.38 / 5.40 / 5.42 so we learn early about per-version differences.
    Where the codebase would conceptually use roles (e.g.,
    `PayloadCodec` as a role, `WorkflowDefinition`-being-a-mixin), we
    use inheritance and document it as a "would be a role in a future
    Perl"; migration when roles ship will be mechanical.

---

## 17. `temporalio-perl-bridge` distribution shape — resolved

**Decision: (A) Two Alien distributions.**

`Alien-Temporalio-Core` (upstream-tracking, fetches sdk-rust tarball,
builds `libtemporalio_sdk_core_c_bridge`) and `Alien-Temporalio-PerlBridge`
(our code, in-tree `ext/temporalio-perl-bridge/`, builds
`libtemporalio_perl_bridge`). The bridge Alien declares a build-time
dep on the core Alien so cbindgen can pick up the upstream header.

Rationale: lockstep was the *wrong* reason to bundle. Bundling would
force `Alien-Temporalio-Core` to release every time the Perl-side
trampoline changes, confusing version-tracking against sdk-rust releases.
Separation lets each Alien track its own upstream cadence. The model is
`Alien::OpenSSL` (single upstream tarball, multiple libraries) vs.
`Alien::libxml2` + downstream `XML::LibXML` (separate Aliens for separate
codebases). Ours is the latter pattern: sdk-core is upstream, our shim
is not.

Repository layout (already updated in §1):
- `alien-core/` — `Alien::Temporalio::Core` distribution
- `alien-perl-bridge/` — `Alien::Temporalio::PerlBridge` distribution
- `ext/temporalio-perl-bridge/` — Rust source built by the second Alien

---

# Part II — v0.2 feature parity

The sections below (§18+) are the detailed contracts for the v0.2
phases declared in §11. Each mirrors the cross-SDK-consistent behavior
of sdk-python and sdk-ruby per the prime directive (§0); proto anchors
are in the vendored trees under `sdk/share/proto/temporal/sdk/core/`.
Phase 6 (workflow parity) is §18–§20.

## 18. Child workflows — `Temporalio::Workflow::{execute,start}_child_workflow` (v0.2, Phase 6)

**Files:** `sdk/lib/Temporalio/Workflow.pm` (functional surface),
`sdk/lib/Temporalio/Workflow/ChildWorkflowHandle.pm` (handle, new),
`sdk/lib/Temporalio/Workflow/Commands.pm` (command builders),
`sdk/lib/Temporalio/Workflow/Runner.pm` (seq allocation, job application).

A child workflow is started by the workflow body, runs as an independent
execution, and resolves in **two stages** — *start* (the child has been
scheduled with a run id) and *result* (the child reached a terminal
state). This two-stage shape is the only structural difference from
activities (§10.2): one `StartChildWorkflowExecution` command produces
*two* activation jobs — `ResolveChildWorkflowExecutionStart`, then later
`ResolveChildWorkflowExecution` — against one seq.

### 18.1 Public API

In-workflow functions (module-level, kwargs, awaitable), mirroring
`execute_activity`/`start_activity`:

```perl
# Awaits start AND result — resolves to the child's return value.
my $result = await Temporalio::Workflow::execute_child_workflow(
    $workflow,                       # type-name string | definition class/object
    args                => \@args,   # arrayref (default [])
    id                  => undef,    # default: a DETERMINISTIC generated id (below)
    task_queue          => undef,    # default: the parent's task queue
    cancellation_type   => 'wait_cancellation_completed',
    parent_close_policy => 'terminate',
    id_reuse_policy     => 'allow_duplicate',
    execution_timeout   => undef,    # seconds → workflow_execution_timeout
    run_timeout         => undef,    # seconds → workflow_run_timeout
    task_timeout        => undef,    # seconds → workflow_task_timeout
    retry_policy        => undef,    # Temporalio::Common::RetryPolicy
    cron_schedule       => undef,
    memo                => undef,    # { name => Perl value }
    search_attributes   => undef,
    headers             => {},
);

# Awaits start ONLY — resolves to a handle once the child has STARTED.
my $handle = await Temporalio::Workflow::start_child_workflow($workflow, %opts);
my $result = await $handle->result;
```

Both functions are `async` and are themselves `await`ed: unlike
`start_activity` (which returns a Future synchronously),
`start_child_workflow` suspends until the start job arrives, then
resolves to the handle (mirrors sdk-python `await ... _start_fut` and
sdk-ruby fiber-blocking start). `execute_child_workflow` is the sugar
over `start` + `->result`. The first positional resolves to a
workflow-type name the same way `continue_as_new` does.

**Default `id` (resolved decision).** When `id` is omitted the SDK MUST
supply a *deterministic* id derived from the workflow RNG
(`Temporalio::Workflow::random`), never `rand`/OS entropy, so replay
reproduces it. (sdk-python's `str(uuid4())` default is deterministic only
because it runs under their sandbox-patched RNG; Perl has no global
patch, so the determinism is explicit here.) Authors are encouraged to
pass an explicit `id`.

#### Handle — `Temporalio::Workflow::ChildWorkflowHandle`

Constructed only by `start_child_workflow`; never directly.

```perl
$handle->id;                          # child workflow id
$handle->first_execution_run_id;      # run id from start-success
my $r = await $handle->result;        # child return value, or raises the mapped failure
await $handle->signal($name, args => \@args);   # SignalExternalWorkflowExecution (child_workflow_id target)
$handle->cancel;                      # CancelChildWorkflowExecution { child_workflow_seq }
```

`result` is idempotent (same resolved Future). `signal` targets the
`child_workflow_id` oneof arm (not `workflow_execution`). **`cancel` is an
explicit handle method (resolved decision):** Ruby routes child cancel
through a `Cancellation` token and Python through task cancellation;
neither has a literal `->cancel`. Perl exposes `->cancel` for parity with
the Runner's existing activity/timer Future-cancel model — the *behavior*
(emit `CancelChildWorkflowExecution`, honor `cancellation_type`) is
cross-SDK-consistent; only the surface differs.

#### Enums (lowercase string constants → proto numbers, mapped in the Runner)

Follows the existing `cancellation_type` precedent (§10.2). Authors pass
strings; no constants module.

- `cancellation_type` → `ChildWorkflowCancellationType`: `abandon`=0,
  `try_cancel`=1, `wait_cancellation_completed`=2,
  `wait_cancellation_requested`=3. **Default `wait_cancellation_completed`**
  (NOT the proto zero `abandon`, NOT activities' `try_cancel`).
- `parent_close_policy` → `ParentClosePolicy`: `unspecified`=0,
  `terminate`=1, `abandon`=2, `request_cancel`=3. **Default `terminate`.**
- `id_reuse_policy` → `WorkflowIdReusePolicy`. **Default `allow_duplicate`.**

### 18.2 Behavioral contract

**Seq.** Child workflows use a **separate seq space**
(`$child_workflow_seq_counter` from 1), distinct from activity and timer
counters — a workflow's first child, first activity, and first timer are
each seq 1 in their own space.

**Start.** The Runner's `start_child_workflow(%opts)`: allocates seq;
converts args/memo/headers to payloads, retry/search-attributes to proto,
the three timeouts to `google.protobuf.Duration` (before building the
command, so converter errors surface at the call site); resolves `id`,
`task_queue`, and the three enums; buffers a `StartChildWorkflowExecution`
command; registers a **start Future** and **result Future** in
`%pending_child_workflows{$seq}` wrapped in a `ChildWorkflowHandle`;
returns the start Future.

**`ResolveChildWorkflowExecutionStart`:** `succeeded` → set
`first_execution_run_id`, `->done` the start Future, **do not** pop the
seq (the result job still comes); `failed` → pop, `->fail` the start
Future (`WorkflowAlreadyStarted` on `WORKFLOW_ALREADY_EXISTS`, else a
generic error); `cancelled` → pop, `->fail` the start Future with
`Cancelled` (from the core-built `ChildWorkflowFailure`→`CancelledFailure`).

**`ResolveChildWorkflowExecution`:** look up by seq (unknown seq → a
non-determinism error via the existing `_record_nondeterminism`); read
`ChildWorkflowResult` — `completed` → `->done` with the converted result;
`failed`/`cancelled` → `->fail` via the failure converter; pop the seq.

**Cancellation propagation.** `$handle->cancel`, or a `CancelWorkflow`
job propagating down the tree (extend `_apply_cancel_workflow`, which
already cancels pending activity/timer Futures, to also cancel pending
child handles), emits `CancelChildWorkflowExecution { child_workflow_seq }`
— except under `abandon`, which stops waiting and emits no command
(parallels the activity ABANDON branch). Under
`wait_cancellation_completed` the body stays parked on `result` until the
cancelled resolve arrives. `parent_close_policy` is a start-command field
only; the server enforces the child's fate when the parent closes.

**Determinism.** Monotonic per-space seq; RNG-derived default id; pure
conversions — identical replay guarantees to §10.2/§10.3.

### 18.3 Failure modes

- **`WorkflowAlreadyStarted`** — start-failure cause
  `WORKFLOW_ALREADY_EXISTS` fails the *start* await (before any result),
  carrying `workflow_id`/`workflow_type`.
- **Other start-failure cause** — generic `Temporalio::Exception`.
- **Cancelled before start** — `Temporalio::Exception::Cancelled`; no
  result job follows.
- **Result failure** — `ResolveChildWorkflowExecution{failed}` fails the
  *result* Future with **`Temporalio::Exception::ChildWorkflow`** (existing
  §6.2 class) whose `cause` is the underlying failure;
  `result{cancelled}` → `ChildWorkflow` with cause `Cancelled`.
- **Unknown-seq resolve** — non-determinism error (T-wf-13 routing).

### 18.4 Test scenarios

Replay (`sdk/t/replay/child_workflows.t`, the `activations.t` pattern;
fixtures in `sdk/t/lib/WfDef/`):

- **T-child-1** — `start_child_workflow` emits one
  `StartChildWorkflowExecution` (seq 1, type, id, parent task_queue,
  `parent_close_policy=1`, `cancellation_type=2`, reuse `allow_duplicate`,
  converted args); body parks, no completion command.
- **T-child-2** — `ResolveChildWorkflowExecutionStart{succeeded{run_id}}`
  resolves start; `first_execution_run_id == run_id`; a `start` workflow
  completes (returns the handle id), an `execute` workflow stays parked.
- **T-child-3** — `ResolveChildWorkflowExecution{completed{result}}`
  resumes `execute_child_workflow`; workflow completes with the converted
  result.
- **T-child-4** — result `failed{failure}` raises
  `Temporalio::Exception::ChildWorkflow` (cause = mapped failure); workflow
  fails per the §10.3 outcome table.
- **T-child-5** — start `failed{cause: WORKFLOW_ALREADY_EXISTS}` →
  `WorkflowAlreadyStarted` on the start await; no result job.
- **T-child-6** — start `cancelled{failure}` → `Cancelled` on start.
- **T-child-7** — `$handle->cancel` emits
  `CancelChildWorkflowExecution{seq 1}`; subsequent `cancelled` resolve →
  `ChildWorkflow`/`Cancelled`. With `cancellation_type=abandon`, assert no
  cancel command is emitted.
- **T-child-8** — two children get seq 1, 2 (separate space; a child and
  an activity are both seq 1); out-of-order resolution settles the right
  handles.
- **T-child-9** — `$handle->signal` emits `SignalExternalWorkflowExecution`
  with the `child_workflow_id` arm set (not `workflow_execution`).
- **T-child-10** — enum string mapping (`parent_close_policy 'abandon'`→2,
  `cancellation_type 'try_cancel'`→1, bad string dies at scheduling time).
- **T-child-11** — a `CancelWorkflow` job cancels a pending child handle
  (emits the cancel unless abandon) and fails the awaiting `result`
  (mirrors T-act-9).
- **T-child-12** — omitting `id` yields a deterministic id (re-running the
  init activation reproduces it).
- **T-child-13** *(integration, `sdk/t/integration/child_workflows.t`,
  `skip_all` without a dev server)* — a parent `execute_child_workflow`s a
  real registered child and asserts the value; a second case signals the
  child via the handle; a third asserts a failing child surfaces
  `ChildWorkflow`.

### 18.5 Reference anchors (MUST-match)

Protos (`sdk/share/proto/temporal/sdk/core/`):
`StartChildWorkflowExecution` `workflow_commands/workflow_commands.proto:240-273`;
`CancelChildWorkflowExecution{child_workflow_seq}` `:276-284`;
`SignalExternalWorkflowExecution` child arm `:295-303`;
`ResolveChildWorkflowExecutionStart(+Success/Failure/Cancelled)`
`workflow_activation/workflow_activation.proto:234-262`;
`ResolveChildWorkflowExecution` `:265-269`; `ChildWorkflowResult`
`child_workflow/child_workflow.proto:11-34`; `ParentClosePolicy` `:38-47`;
`StartChildWorkflowExecutionFailedCause` `:50-53`;
`ChildWorkflowCancellationType` `:56-65`.
sdk-python: `temporalio/workflow/_workflow_ops.py:53-510` (handle, ops,
defaults, enum maps); `temporalio/worker/_workflow_instance.py:859-931,
1977-2017, 3205-3343` (start/result resolution, seq space, command
mapping). sdk-ruby: `workflow.rb:206-224,442-460`,
`workflow/child_workflow_handle.rb:8-49`, `parent_close_policy.rb`,
`child_workflow_cancellation_type.rb`.

## 19. Workflow updates — `:Update`/`:UpdateValidator` dispatch + client update calls (v0.2, Phase 6)

**Files:** `sdk/lib/Temporalio/Workflow/Runner.pm` (DoUpdate dispatch),
`sdk/lib/Temporalio/Workflow/Commands.pm` (UpdateResponse builder),
`sdk/lib/Temporalio/Client/WorkflowHandle.pm` (client calls),
`sdk/lib/Temporalio/Client/WorkflowUpdateHandle.pm` (new),
`sdk/lib/Temporalio/Exception/WorkflowUpdateFailed.pm` (new).

The `:Update`/`:UpdateValidator` attributes already parse in
`Workflow::Definition` (registries exist); this section adds dispatch. An
update is a **two-phase** job inside the runner: a synchronous validation
phase (read-only, query-like — must not mutate state or emit commands)
then an asynchronous execution phase (signal-like — tracked for
completion gating). On the client it is a blocking `UpdateWorkflowExecution`
RPC governed by a wait-for-stage policy, with `PollWorkflowExecutionUpdate`
to retrieve the outcome.

### 19.1 Public API

**Workflow side:** `:Update`/`:Update('name')`/`:Update(dynamic=1)` marks
an update handler (name defaults to the method name; `(dynamic=1)` is the
catch-all called as `($name, @args)`, mirroring `:Signal(dynamic=1)`); a
handler may be `async` and may return a result.
`:UpdateValidator('updateName')` pairs a **synchronous** validator with
the named update — same parameter signature as the handler, MUST NOT
mutate state / await / issue commands / return a meaningful value; a
validator that throws *rejects* the update. There is no dynamic validator
(a named update with no validator is treated as accepted; the dynamic
handler is never validated).

**Client side** (on `Temporalio::Client::WorkflowHandle`):

```perl
# Sugar: start with wait_for_stage 'completed', return the decoded result.
my $r = await $handle->execute_update($name, \@args, %opts);

# Returns a Temporalio::Client::WorkflowUpdateHandle.
my $uh = await $handle->start_update($name, \@args, wait_for_stage => 'accepted', %opts);
my $r  = await $uh->result;     # polls if needed; returns decoded result or throws
```

`wait_for_stage` maps `'accepted'`→`..._ACCEPTED`(2),
`'completed'`→`..._COMPLETED`(3). `'admitted'`(1) is **rejected** with
`Temporalio::Exception::Argument` (not a supported wait stage). `%opts`
accepts an explicit `update_id` (default: a fresh UUID) and
`rpc_metadata`/`rpc_timeout`. `WorkflowUpdateHandle` carries
`workflow_id`, `run_id`, `update_id`, a client back-reference, and any
known outcome.

### 19.2 Behavioral contract

**Runner — `_apply_do_update`** (dispatched from `_apply_job` for variant
`do_update`):

1. **Ordering.** `DoUpdate` sorts into **job set 1** with `SignalWorkflow`
   (the `_ordered_job_sets` comment at Runner.pm:595 already reserves
   this), applied before `InitializeWorkflow` (set 2), with
   `_pump(check_conditions => 1)` after. An update arriving in the init
   activation (no instance yet) is **buffered** like a pre-instance signal
   and re-applied after `_apply_initialize` (mirrors `%pending_signals`).
2. **Lookup.** Resolve `defs->{updates}{$name}` then `defs->{dynamic}{update}`.
   No handler on a live instance → **reject immediately** with
   `UpdateResponse.rejected` ("Update handler for '$name' expected but not
   found, and there is no dynamic handler"). Unlike signals, updates get
   no indefinite buffering for a never-registered handler.
3. **Validation (sync, read-only).** Only when the job's `run_validator`
   is true AND a validator is registered: run it under a read-only guard
   (dynamically-scoped flag, like the query path, that makes any
   command/mutation throw). Validator **throws** → one
   `UpdateResponse.rejected` (converted failure); workflow unaffected.
   Validator **returns** (or none ran) → `UpdateResponse.accepted`, then
   the handler. A validator that mutates/commands is a **workflow task
   failure**, not a rejection. `run_validator` is false on replay, so the
   accept/reject decision recorded in history is reproduced without
   re-validating.
4. **Execution (async, tracked).** Invoke the handler via `Future->call`
   (sync or async, as `_dispatch_signal`); register the pending Future in
   the existing `%in_progress_handlers` set so `_all_handlers_finished`
   gates `CompleteWorkflowExecution` while the handler is in-flight
   (existing Runner.pm:1034 gate, no change). Handler **returns** →
   `UpdateResponse.completed` with the encoded result. Handler **throws** a
   Temporal-failure exception (a mapped `Temporalio::Exception::*`, or a
   class in the worker's failure-exception types) →
   `UpdateResponse.rejected` (completed-with-failure). **Any other** `die`
   post-acceptance is a **workflow task failure**, not an update failure.
   An accepted update emits **two** `UpdateResponse` commands
   (`accepted`, then `completed`/`rejected`), possibly across activations;
   a pre-acceptance rejection emits **one**. All carry the job's
   `protocol_instance_id`.

**Completion gating (resolved decision).** Perl follows sdk-python's
*hard* gate (already implemented via `%in_progress_handlers`): updates
slot into the same set as signals, so completion waits on in-flight
update handlers. (sdk-ruby is advisory/warn-only; Perl is deliberately
stricter, matching existing code.)

**Client side.** Build `UpdateWorkflowExecutionRequest` (namespace,
`workflow_execution`, `first_execution_run_id`,
`wait_policy.lifecycle_stage` = mapped stage, `request.meta{update_id,
identity}`, `request.input{name, args}`; args converter-encoded). Call
`UpdateWorkflowExecution` via `_rpc_call` in a **retry loop** until the
response `stage` is at least `..._ACCEPTED` (durability). Seed the
`WorkflowUpdateHandle` with the ref and any returned `outcome`.
`execute_update` and `start_update(wait_for_stage=>'completed')` then poll
to the outcome via `PollWorkflowExecutionUpdate`
(`wait_policy.lifecycle_stage = ..._COMPLETED`, looping with transient
retry like `result()`'s long-poll); `start_update(wait_for_stage=>
'accepted')` returns the handle without polling. **Outcome decode:**
`outcome.success` → decode the single result payload (warn if >1);
`outcome.failure` → throw `Temporalio::Exception::WorkflowUpdateFailed`
whose `cause` is the decoded failure.

### 19.3 Failure modes

- **Validator rejection** — not retryable; caller sees
  `WorkflowUpdateFailed` (cause = decoded validator failure); workflow
  unaffected. No `accepted`/`completed` emitted.
- **Handler exception (Temporal-failure type)** — update fails;
  `WorkflowUpdateFailed` (cause = decoded failure); workflow keeps running.
- **Handler exception (non-Temporal `die`)** — workflow task failure (WFT
  retried), NOT an update failure.
- **Unknown update name** (live instance, no dynamic handler) — immediate
  `UpdateResponse.rejected`.
- **Update on a closed workflow** — the RPC fails; mapped via the §7.5
  table.
- **`wait_for_stage => 'admitted'`** — `Exception::Argument` before any RPC.
- **RPC deadline/cancellation during start or poll (resolved decision)** —
  distinct from the update's own outcome; v0.2 maps it onto the existing
  `Exception::Timeout`/`Cancelled` rather than a dedicated
  `WorkflowUpdateRPCTimeoutOrCancelled` subclass (divergence from
  Python/Ruby, which have a dedicated class — noted).

### 19.4 Test scenarios

Workflow-side (replay, `sdk/t/replay/updates.t`):

- **T-upd-1** — accepted update (non-mutating validator + sync handler
  returning a value): command buffer is exactly
  `[accepted, completed{result}]` with the right `protocol_instance_id`.
- **T-upd-2** — validator throws → single `rejected{failure}`, no
  `accepted`, body state untouched.
- **T-upd-3** — no validator (or `run_validator:false`) → `accepted`
  unconditionally before the handler.
- **T-upd-4** — async handler awaiting an activity: `accepted` in the
  first activation, workflow NOT completed while the handler Future is
  pending, `completed` in the activation resolving the activity.
- **T-upd-5** — handler throws `ApplicationError` post-acceptance →
  `rejected{failure}`, workflow not failed.
- **T-upd-6** — handler `die "boom"` post-acceptance → workflow task
  failure, NOT `rejected`.
- **T-upd-7** — `DoUpdate` in the init activation is buffered and
  dispatched after init, in arrival order vs signals.
- **T-upd-8** — unknown name, no dynamic handler → immediate `rejected`.
- **T-upd-9** — dynamic handler receives `($name, @args)` and emits
  `accepted`/`completed`; dynamic handler is not validated.
- **T-upd-10** — validator issuing a command → workflow task failure.
- **T-upd-11** — replay with `run_validator:false`: validator not invoked,
  same `accepted`/`completed` reproduced.

Client-side (integration, `sdk/t/integration/updates.t`, `skip_all`
without a dev server):

- **T-cli-update-1** — `execute_update` returns the decoded result.
- **T-cli-update-2** — `start_update(wait_for_stage=>'accepted')` returns a
  handle; later `->result` returns the completed result (poll path).
- **T-cli-update-3** — validator-rejected update → `execute_update` raises
  `WorkflowUpdateFailed`; workflow still running.
- **T-cli-update-4** — handler `ApplicationError` → `WorkflowUpdateFailed`
  (cause = the `ApplicationError`).
- **T-cli-update-5** — `wait_for_stage=>'admitted'` → `Exception::Argument`
  before any RPC.
- **T-cli-update-6** — update on a closed workflow → mapped §7.5 exception.
- **T-cli-update-7** — explicit `update_id` round-trips into
  `Request.meta.update_id` and the handle.

### 19.5 Reference anchors (MUST-match)

Protos: `workflow_activation.proto:329-352` (DoUpdate + `run_validator`);
`workflow_commands.proto:330-356` (UpdateResponse variants);
`request_response.proto:1762-1806,1904-1932` (Update/Poll RPCs +
`stage`); `enums/v1/update.proto:21-35` (lifecycle stage);
`update/v1/message.proto` (WaitPolicy, Request, Outcome).
sdk-python: `worker/_workflow_instance.py:608-724` (`_apply_do_update`),
`:1142-1143` (gating), `:2939-2941` (no dynamic validator);
`workflow/_handlers.py`, `_definition.py:350-356`; `_workflow.py:836,
955-956,1894-1984`, `_impl.py:735-757`, `_exceptions.py:73-85`.
sdk-ruby: `internal/worker/workflow_instance.rb:500-590`,
`workflow/definition.rb:197-220`, `client/implementation.rb:469-471,
504-579`, `workflow_update_handle.rb:52-68`, `error.rb:72`.
Perl precedent: Runner.pm:595 (job-set comment), :842-843/:956/:1034
(handler tracking + gate), Definition.pm:60-86; client `signal`/`query`
shape in `WorkflowHandle.pm:209-267`.

## 20. External workflow handles (v0.2, Phase 6)

**Files:** `sdk/lib/Temporalio/Workflow.pm`,
`sdk/lib/Temporalio/Workflow/ExternalWorkflowHandle.pm` (new),
`sdk/lib/Temporalio/Workflow/Commands.pm`,
`sdk/lib/Temporalio/Workflow/Runner.pm`.

A workflow body obtains a handle to an arbitrary already-running workflow
(by id, in the current namespace) and signals or cancels it **through the
command stream** — never via a client RPC. This is the in-workflow
counterpart to the client-side `WorkflowHandle->signal`/`->cancel`, and is
distinct from child workflows (an external handle targets a workflow this
run did not start).

### 20.1 Public API

```perl
my $h = Temporalio::Workflow::get_external_workflow_handle($workflow_id, run_id => undef);
$h->workflow_id;  $h->run_id;
await $h->signal($signal, args => \@args);   # SignalExternalWorkflowExecution
await $h->cancel;                            # RequestCancelExternalWorkflowExecution
```

`get_external_workflow_handle` is a **synchronous, non-command**
constructor — it captures `($workflow_id, $run_id)` plus the runner
reference, emits nothing (mirrors Python/Ruby plain, non-async
constructors); raises `Temporalio::Exception::Workflow::NoRunner` outside
a workflow body. `run_id` undef targets the most-recent run.
`ExternalWorkflowHandle` lives in
`Temporalio::Workflow::ExternalWorkflowHandle`, is never instantiated
directly. `signal($signal, args => [])` and `cancel()` are `async`,
returning a `Workflow::Future` that resolves to nothing on success.

### 20.2 Behavioral contract

Both operations follow the timer/activity precedent (§10.3): allocate a
deterministic seq, emit one command, register the seq → a fresh
`Workflow::Future`, resolve it on the matching `Resolve*` job. The Runner
owns **two independent seq counters** — external-signal and
external-cancel (mirrors Python `_next_seq("external_signal")` /
`"external_cancel"`, Ruby's two counters) — separate from timer/activity.

**signal:** resolve `$signal` to a name; convert `args` to payloads;
allocate the external-signal seq; emit `SignalExternalWorkflowExecution`
(the **`workflow_execution`** oneof arm, not `child_workflow_id`) with
`seq`, `signal_name`, `args`, and `workflow_execution =
NamespacedWorkflowExecution{namespace, workflow_id, run_id}`. **`namespace`
is the current workflow's namespace** from `Temporalio::Workflow::info`
(never a user argument); `run_id` empty when undef. On
`ResolveSignalExternalWorkflow{seq, failure}`: pop; unset failure → done;
populated → fail via `failure_converter->from_failure`.

**cancel:** allocate the external-cancel seq; emit
`RequestCancelExternalWorkflowExecution` with `seq` and the same
`workflow_execution` (reason unset). On
`ResolveRequestCancelExternalWorkflow{seq, failure}`: same done/fail rule.

**Wait semantics:** both resolve only when the `Resolve*` job arrives (the
server-acknowledged send / cancel-request). No fire-and-forget variant.

**In-flight cancellation:** if a `signal`'s awaiting frame is cancelled
before its resolve, the Runner emits `CancelSignalWorkflow{seq}` and lets
the eventual `Resolve*` settle the Future (mirrors Python `asyncio.shield`
+ `cancel_signal_workflow`, Ruby's cancel callback). A `cancel` request
has **no** counter-cancel ("there is no cancelling a cancel request").

Three new `Commands` builders: `signal_external_workflow_execution`,
`request_cancel_external_workflow_execution`, `cancel_signal_workflow`.

### 20.3 Failure modes

No bespoke `ExternalWorkflow` exception (resolved decision): both
references raise `from_failure(resolution.failure)` verbatim. External
workflow not found / signal-send failed / cancel-request failed → the
converted `Temporalio::Exception::Application` (the server's
`application_failure_info`) at the await site. A server-reported cancelled
operation → `Temporalio::Exception::Cancelled`. The constructor's only
failure mode is `NoRunner`.

### 20.4 Test scenarios

Replay (`sdk/t/replay/external_workflow.t`):

- **T-ext-1** — constructor outside a body raises `NoRunner`; inside,
  returns a handle echoing `workflow_id`/`run_id` and emits no command.
- **T-ext-2** — `await $h->signal('go', args => ['x'])` emits one
  `SignalExternalWorkflowExecution` (seq 1, `workflow_execution` arm:
  namespace = run's namespace, workflow_id = handle id, run_id empty when
  undef; `signal_name='go'`; encoded args). Assert `child_workflow_id` arm
  unset.
- **T-ext-3** — `ResolveSignalExternalWorkflow{seq 1}` (no failure)
  resolves done; run completes.
- **T-ext-4** — resolve with `failure: <application "not found">` →
  `Exception::Application` (message/type round-trip).
- **T-ext-5** — `await $h->cancel` emits one
  `RequestCancelExternalWorkflowExecution` (seq 1, same
  `workflow_execution`, reason unset).
- **T-ext-6** — `ResolveRequestCancelExternalWorkflow{seq 1}` resolves
  done; with failure → `Application`.
- **T-ext-7** — independent seq spaces: two signals then a cancel →
  signals seq 1,2 and cancel seq 1; out-of-order resolves settle correctly.
- **T-ext-8** — explicit `run_id` threads into
  `NamespacedWorkflowExecution.run_id` for both commands.
- **T-ext-9** — cancelling an in-flight `signal`'s frame emits
  `CancelSignalWorkflow{seq}` (does not pre-emptively raise); the
  subsequent `Resolve*` settles the Future.
- **T-ext-10** *(integration, `sdk/t/integration/external_workflow.t`)* —
  workflow B signals then cancels workflow A by id; assert A observes the
  signal and reaches a cancelled state; signalling a non-existent id →
  `Application`. `skip_all` without a dev server.

### 20.5 Reference anchors (MUST-match)

Protos: `workflow_commands.proto:285-311` (RequestCancel/Signal external
with `target` oneof), `:313+` (CancelSignalWorkflow);
`workflow_activation.proto:311-327` (Resolve jobs);
`common/common.proto:9-15` (NamespacedWorkflowExecution, run_id may be
empty). sdk-python: `workflow/_workflow_ops.py:551-655`,
`worker/_workflow_instance.py:1009-1055,2104-2118,2578-2601,3366-3394`.
sdk-ruby: `workflow.rb:294-296`, `workflow/external_workflow_handle.rb:10-41`,
`internal/worker/workflow_instance/outbound_implementation.rb:25-58,218-281`,
`workflow_instance.rb:389-395`.

---

# Phase 7 — Activity feature parity (§21–§24)

## 21. Local activities (v0.2, Phase 7)

The local-activity analog of `execute_activity` (§10.2): same scheduling
shape and the same activity seq space / `%pending_activities`, a different
command (`ScheduleLocalActivity`/`RequestCancelLocalActivity`), and one
genuinely new mechanism — the local-backoff → server-timer conversion.
sdk-core runs the LA in-process during the workflow task with no server
round-trip and owns marker recording, WFT heartbeating, and the local
executor; **the worker side (`Worker.pm`, dispatcher, poll loop) is
unchanged** (resolved decision D5). Other resolved decisions: timeouts in
**seconds** (Ruby idiom, v0.1 convention); `cancellation_type` surface
default **`try_cancel`** (follows the references over the proto comment);
no `Cancellation` kwarg in v0.2 (shared §10.2 gap); the backoff loop is
**runner-owned** (D1 — internal structure differs from Python's body-side
`asyncio.shield` loop, observable behavior identical).

### 21.1 Public API

`Temporalio::Workflow::execute_local_activity($activity, %opts)` and
`start_local_activity($activity, %opts)`, mirroring the regular pair
(`execute_*` awaits the returned `Workflow::Future`; `start_*` returns it
un-awaited). `$activity` resolves to an activity-type string via the
existing `_activity_type_name`.

```perl
my $result = await Temporalio::Workflow::execute_local_activity(
    'My::Activity::SayHello',
    args                      => ['Temporal'],
    start_to_close_timeout    => 5,            # seconds
    schedule_to_close_timeout => 30,
    retry_policy              => $rp,
    local_retry_threshold     => 60,           # seconds; backoff above this → server timer
    cancellation_type         => 'try_cancel', # try_cancel|wait_cancellation_completed|abandon
    activity_id               => undef,
    summary                   => undef,
);
```

kwargs (MUST-match the union of sdk-python `start_local_activity` and
sdk-ruby `execute_local_activity`):

| kwarg | default | notes |
|---|---|---|
| `args` | `[]` | converted to payloads at the call site |
| `schedule_to_close_timeout` | unset | inclusive of all retries |
| `schedule_to_start_timeout` | unset | non-retryable; clamped `<= s2c` |
| `start_to_close_timeout` | unset | per-attempt; retryable |
| `retry_policy` | unset | **LAs retry indefinitely by default** (differs from regular activities) |
| `local_retry_threshold` | 60 | backoff above this → server timer |
| `cancellation_type` | `try_cancel` | |
| `activity_id` | seq string | advanced |
| `summary` | unset | → `user_metadata.summary` |

At least one of `start_to_close_timeout` / `schedule_to_close_timeout`
MUST be set (reuses the §10.2 check).

### 21.2 Behavioral contract

**Command emission.** A new `Runner::schedule_local_activity(%opts)`, a
near-clone of `schedule_activity`, that: (1) allocates from the **same**
activity seq space (`++$activity_seq_counter`, registers in
`%pending_activities` — LA and regular handles share the map, mirroring
sdk-python); (2) emits `Commands::schedule_local_activity(\%fields)` with
proto `ScheduleLocalActivity` fields (`seq`, `activity_id`,
`activity_type`, `headers`, `arguments`, the three timeouts,
`retry_policy`, `local_retry_threshold`, `cancellation_type`, plus
`attempt`/`original_schedule_time` **only on a backoff re-schedule**); no
`task_queue`/`heartbeat_timeout`/`priority`; (3) `summary` →
`command.user_metadata.summary`.

**Local execution.** sdk-core dispatches the LA to the worker's
local-activity executor (reusing the activity-definition registry +
fork pool for sync activities), runs it in the same workflow task, records
markers, and WFT-heartbeats if needed. None of this is lang's job — lang
emits the command and consumes the `ResolveActivity`.

**Local backoff → persistent timer (the new mechanism).** When core
decides the next-attempt backoff exceeds `local_retry_threshold`, it
resolves with `ActivityResolution.backoff` (`DoBackoff{attempt,
backoff_duration, original_schedule_time}`) instead of retrying. The
**runner** then (a) starts a real `StartTimer` for `backoff_duration`
(cancellable), (b) on fire re-emits `ScheduleLocalActivity` for the same
type/args with a **new seq**, `attempt = DoBackoff.attempt`, and the
preserved `original_schedule_time`, (c) re-registers the pending entry
under the new seq. The body holds one stable **outer** `Workflow::Future`,
resolved only on a terminal `completed`/`failed`/`cancelled` — it is
unaware of backoff (runner-owned loop, D1).

**`ResolveActivity` handling.** LA resolutions arrive on the same
`ResolveActivity` job as regular activities (distinguished by the `backoff`
status; the `is_local` flag is informational). `_apply_resolve_activity`
gains a fourth branch: `completed`/`failed`/`cancelled` resolve the outer
future terminally (as today); `backoff` runs the timer + re-schedule loop
without resolving the outer future.

**Cancellation types.** `try_cancel` (default) → emit
`RequestCancelLocalActivity{seq}` and immediately resolve the outer future
`Cancelled`; `wait_cancellation_completed` → emit the cancel but wait for a
`ResolveActivity{cancelled}` job; `abandon` → emit **no** command and
resolve `Cancelled` immediately. A backing-off LA cancelled on its server
timer → cancel the pending timer (`CancelTimer`) + resolve `Cancelled`.
`RequestCancelLocalActivity` via a new
`Commands::request_cancel_local_activity($seq)`.

**Worker shutdown** is core-side: lang keeps draining activations and must
not treat a late LA resolve for an evicting workflow as non-determinism
(the backoff re-schedule must register its new seq so the late resolve is
recognized).

### 21.3 Failure modes

- **No timeout set** → die at the call site (reuses the §10.2 check).
- **Arg/result conversion error** → surfaces at the call site before the
  command is buffered.
- **Activity fails, retries remain** → core retries locally; no resolve
  reaches lang until terminal.
- **Non-retryable failure** → core resolves `failed`; runner fails the
  outer future with the converted `ApplicationFailure` (no LA-specific
  code; `non_retryable_error_types` is a normal RetryPolicy field).
- **`backoff` for an unknown/cancelled seq** → tolerate as stale per the
  existing cancelled-seq path; an unknown seq with no pending entry is
  non-determinism.
- Re-schedule after backoff MUST use the new seq + `attempt` +
  `original_schedule_time`, or replay breaks.

### 21.4 Test scenarios

Replay (`sdk/t/replay/local_activities.t`), each mapped to a
`features/features/local_activity/` scenario:

- **T-local-1** `complete_immediately` — one `ScheduleLocalActivity`; value
  returned in the same WFT.
- **T-local-2** `complete_eventually` — LA outlives a WFT; lang keeps
  draining; value reaches the body.
- **T-local-3** `serial` — three LAs in order; three commands.
- **T-local-4** `concurrent` — three un-awaited then jointly awaited; share
  `%pending_activities`.
- **T-local-5** `retry_on_error` — fails to max_attempts; only the terminal
  failure reaches lang.
- **T-local-6** `non_retryable_error_from_activity` — non-retryable
  `ApplicationError`; resolved `failed`, no retry.
- **T-local-7** `non_retryable_error_in_options` — `non_retryable_error_types`
  match; same as T-local-6, no LA-specific path.
- **T-local-8** `one_success_one_fail` — two concurrent; each outer future
  resolves independently.
- **T-local-9** `backoff_with_persistent_timer` — `backoff` → `StartTimer`
  → re-schedule (new seq, attempt, original_schedule_time); body's await
  unaffected.
- **T-local-10/11/12** `cancel_try_cancel`/`cancel_wait_completed`/`cancel_abandon`
  — the three cancellation-type behaviors above.
- **T-local-13** `cancel_failing` — backing-off LA cancelled → `CancelTimer`
  + `Cancelled`.
- **T-local-14/15** `shutdown_sends_cancellation`/`complete_after_shutdown`
  — lang tolerates late LA resolves without non-determinism; no stuck
  workflow.

### 21.5 Reference anchors (MUST-match)

Protos: `ScheduleLocalActivity`/`RequestCancelLocalActivity`/`ActivityCancellationType`
`workflow_commands.proto:104-167`; `DoBackoff`/`ActivityResolution.backoff`
`activity_result/activity_result.proto:23-76`; `ResolveActivity`+`is_local`
`workflow_activation.proto:223-229`. sdk-python
`workflow/_activities.py:1131-1474`, `worker/_workflow_instance.py:810-857`
(backoff branch), `:1880-1932` (schedule loop), `:3103-3193` (resolve_backoff,
LA fields), `:3195-3202` (cancel). sdk-ruby `workflow.rb:228-287`. Perl host
code: `Workflow.pm`, `Workflow/Runner.pm` (schedule_local_activity,
backoff branch), `Workflow/Commands.pm`.

## 22. Async activity completion (v0.2, Phase 7)

An activity body can declare it will complete **out of band**; some external
process later completes/fails/cancels/heartbeats it through a client-side
handle, addressed by opaque **task token** or **id reference**
(`workflow_id` + optional `run_id` + `activity_id`) — the "id-or-token"
union both reference SDKs converge on.

### 22.1 Public API

**Worker side** — a new public exception
`Temporalio::Exception::Activity::CompleteAsync` and a package verb
`Temporalio::Activity::complete_async` that throws it (resolved decision:
ship the verb + public class, no context method). The activity dispatcher
(`Worker/ActivityDispatcher.pm`) catches it specifically and reports
`activity_result.ActivityExecutionResult{will_complete_async}` to core
instead of Completed/Failed. (Caveat: catching/swallowing `CompleteAsync`
in user code defeats async completion — the dispatcher only honors it when
it propagates out of the body.)

**Client side** — a keyword-union factory (resolved decision: keyword-only,
no public `ActivityIDReference` value object in v0.2):

```perl
my $h = $client->async_activity_handle(task_token => $bytes);
my $h = $client->async_activity_handle(workflow_id => $w, run_id => $r, activity_id => $a);

await $h->heartbeat(@details);                 # may throw AsyncActivityCancelled
await $h->complete($result);                   # $result optional (no-result activities)
await $h->fail($error, last_heartbeat_details => \@details);
await $h->report_cancellation(@details);
```

`task_token` is mutually exclusive with the id triple; `workflow_id`
requires `activity_id`. No RPC at construction. Returns a
`Temporalio::Client::AsyncActivityHandle`.

### 22.2 Behavioral contract

1. Each method picks the `*ById*` RPC for an id reference, else the
   task-token RPC. `namespace` and `identity` are injected from the client
   on every request, both branches.
2. **`heartbeat` inspects the response** and raises
   `Temporalio::Exception::Activity::AsyncActivityCancelled` (carrying a
   cancellation-details value from `cancel_requested`/`activity_paused`/
   `activity_reset`) when any is set — this is the only cancellation-delivery
   channel to an out-of-band activity. (Resolved naming: double-L
   `Cancelled`, matching the existing `Cancelled` class.)
3. `complete` result is optional (empty result payloads for no-result
   activities). `fail` carries `last_heartbeat_details` (default empty).
   Details/result convert through `$client->data_converter`'s payload
   converter (sync path, matching v0.1 heartbeat).
4. RPCs route via `_rpc_call` (`service => 'workflow'`, `retry => 1`).
5. **Proto field-number caution:** in the by-token request messages
   `result`/`failure`/`last_heartbeat_details`/`details` occupy
   **non-sequential** tags (deprecated `worker_version`/`deployment`/
   `resource_id` fields sit between) — encode by explicit field number; set
   only `task_token`/`namespace`/`identity` + payload/failure.

The 8 RPCs (`workflowservice/v1/request_response.proto`):
RecordActivityTaskHeartbeat(ById), RespondActivityTaskCompleted(ById),
RespondActivityTaskFailed(ById), RespondActivityTaskCanceled(ById).

### 22.3 Failure modes

- `task_token` + any id field, or `workflow_id` without `activity_id`, or
  neither → `Temporalio::Exception::Argument`.
- RPC failure (e.g. NOT_FOUND) → mapped `RpcError` via `_rpc_call`.
- `heartbeat` against a cancel/pause/reset response →
  `AsyncActivityCancelled`.

### 22.4 Test scenarios

Integration (`sdk/t/integration/async_activity.t`, skip without dev server):

- **T-asyncact-1/2** — `complete($result)` by token → `RespondActivityTaskCompletedRequest`;
  by-id → the ById variant.
- **T-asyncact-3** — `fail(..., last_heartbeat_details => [...])` (+ById).
- **T-asyncact-4** — `report_cancellation` (+ById).
- **T-asyncact-5** — `heartbeat` success issues the heartbeat RPC; details
  converted.
- **T-asyncact-6** — heartbeat response `cancel_requested`/`activity_paused`/
  `activity_reset` raises `AsyncActivityCancelled` with the right flags.
- **T-asyncact-7** — body calls `complete_async` → `WillCompleteAsync` to
  core; later completed via handle; workflow result reflects the out-of-band
  value (end-to-end).
- **T-asyncact-8** — arg validation (unit): the three invalid combos raise
  `Argument`.
- **T-asyncact-9** — `complete()` with no `$result` sends empty result.

### 22.5 Reference anchors (MUST-match)

sdk-python `client/_client.py:2588-2662`, `client/_activity.py:532-677`,
`client/_impl.py:1000-1136`, `activity.py:441-449`. sdk-ruby
`client.rb:729-737`, `client/async_activity_handle.rb:12-92`,
`internal/worker/activity_worker.rb:281-287`. Protos
`request_response.proto:569-773`. Perl: `Client.pm:403` (_rpc_call),
`Activity/Context.pm:66-80`, `Worker/ActivityDispatcher.pm`.

## 23. Eager start (v0.2, Phase 7)

Two distinct knobs, not to be conflated.

### 23.1 Public API & contract — eager workflow start (detect-only)

`start_workflow(..., request_eager_start => 1)` already sets proto
`StartWorkflowExecutionRequest.request_eager_execution` (`Client.pm:252`).
v0.2 completes the path **detect-only** (resolved decision — the C header
exposes no eager API; the embedded first-task dispatch is owned entirely by
the Rust core when client and worker share a core client; the lang layer
does not route the embedded task): expose a read-only
`$handle->eagerly_started` set from
`StartWorkflowExecutionResponse.eager_workflow_task`. No error if the server
has eager-start disabled — the workflow simply starts normally and
`eagerly_started` is false; integration tests **skip** (not fail) when the
server returns no eager task.

### 23.2 Public API & contract — eager activity dispatch

```perl
my $worker = Temporalio::Worker->new(...,
    disable_eager_activity_execution => 0,   # default 0 (eager ON); workflow-side flag
    no_remote_activities             => 0,   # default 0; bridge enable_remote_activities = !this
);
```

- `disable_eager_activity_execution` is a **workflow-side** flag that
  suppresses the eager-execution request attached when a workflow schedules
  an activity — it threads into the `schedule_activity` command path
  (`Workflow/Commands.pm`/`Runner.pm`), NOT the bridge WorkerOptions.
- `no_remote_activities` **IS** a bridge WorkerOptions field: today
  `Worker.pm` hardcodes `enable_remote_activities => 1`; v0.2 makes it
  `!$no_remote_activities` (and implicitly true when no activities are
  registered). An eager activity declined for lack of remote slots degrades
  to remote scheduling, which may time out **schedule-to-start** (the
  expected compliance outcome).

### 23.3 Test scenarios

- **T-eager-1** — `request_eager_start => 1` sets `request_eager_execution`
  on the wire (unit). *(features/eager_workflow/successful_start)*
- **T-eager-2** — response with `eager_workflow_task` → `eagerly_started`
  true; workflow returns its value; **skips** if the server returned none.
- **T-eager-3** — no `eager_workflow_task` → `eagerly_started` false;
  workflow completes normally.
- **T-eager-4** — `no_remote_activities => 1` sets bridge
  `enable_remote_activities => 0`; worker starts (unit).
  *(features/eager_activity/non_remote_activities_worker)*
- **T-eager-5** — workflow schedules an activity (short schedule-to-close)
  on a `no_remote_activities` worker → eager declined → activity times out
  with type `SCHEDULE_TO_START`.
- **T-eager-6** — `disable_eager_activity_execution => 1` suppresses the
  eager flag on the emitted `schedule_activity` command (unit).

### 23.4 Reference anchors (MUST-match)

sdk-python `client/_client.py:413-549`, `client/_impl.py:182-213`,
`worker/_worker.py:123-288,532-534,624-631`, `bridge/worker.py:48`. Protos
`request_response.proto:169,206-217,295`. Perl `Client.pm:238-253`,
`Client/WorkflowHandle.pm` (add `eagerly_started`), `Worker.pm:100-144`.

## 24. In-workflow upsert of search attributes & memo (v0.2, Phase 7)

In-workflow verbs emitting `UpsertWorkflowSearchAttributes` and
`ModifyWorkflowProperties`.

### 24.1 Public API

```perl
Temporalio::Workflow::upsert_search_attributes(@updates);   # typed updates
Temporalio::Workflow::upsert_memo({ reason => 'x', stale => undef });  # undef removes
```

Search attributes are **typed-only** (resolved decision — adopt Ruby's
surface; reject Python's deprecated untyped-dict form): updates are built
from the existing `Temporalio::Common::SearchAttributeKey` via new
`$key->value_set($v)` / `$key->value_unset` methods. Memo takes a hashref;
an `undef` value removes that key.

### 24.2 Behavioral contract

- `upsert_search_attributes` → `UpsertWorkflowSearchAttributes` (oneof tag
  18): each update encodes into `search_attributes.indexed_fields{key}`;
  `value_unset` writes a proper null Payload (the key is still present); the
  server merges, new values winning. `Workflow::info->{search_attributes}`
  is updated in place (not with `BinaryChecksums`).
- `upsert_memo` → `ModifyWorkflowProperties` (oneof tag 19): writes
  `upserted_memo.fields{key}`; `undef` → empty Payload (deletion convention);
  removals are emitted even for absent keys; the in-workflow memo view stays
  in sync. **Early-return on empty** updates (no command).
- Both **pre-convert** through the workflow's payload converter before
  buffering, so a conversion failure leaves no partial command. New
  `Workflow/Commands.pm` builders following the `$fields`-hashref pattern;
  the public verbs validate `_runner()` and delegate.

### 24.3 Failure modes

- Outside a workflow body → `Temporalio::Exception::Workflow::NoRunner`.
- Unencodable SA/memo value → conversion exception before any command.
- Empty updates → early return, no command, no error.
- Untyped SA mapping passed to `upsert_search_attributes` →
  `Temporalio::Exception::Argument` (resolved decision: reject the
  Python-deprecated overload).

### 24.4 Test scenarios

Replay (`sdk/t/replay/upsert.t`):

- **T-upsert-1** — `value_set` emits one `UpsertWorkflowSearchAttributes`
  with the encoded `indexed_fields{key}`. *(features/search_attributes/upsert)*
- **T-upsert-2** — `value_unset` emits a null Payload (delete), command
  present.
- **T-upsert-3** — two sequential upserts; final
  `info->{search_attributes}` keeps untouched keys, shows cleared/added keys,
  no `BinaryChecksums`.
- **T-upsert-4** — start-time SAs reflected in `info->{search_attributes}`.
  *(features/search_attributes/set)*
- **T-upsert-5** — `upsert_memo({reason=>'x'})` → `ModifyWorkflowProperties`
  with `upserted_memo.fields{reason}`.
- **T-upsert-6** — `upsert_memo({stale=>undef})` → empty Payload (delete),
  command present even if absent.
- **T-upsert-7** — empty updates → no command.
- **T-upsert-8** — conversion failure → raises before any command.
- **T-upsert-9** — either verb outside a workflow body → `NoRunner`.

### 24.5 Reference anchors (MUST-match)

sdk-python `worker/_workflow_instance.py:1294-1336,1659-1762`,
`workflow/_context.py:655-663,845-863`. sdk-ruby `workflow.rb:502-516`.
Protos `workflow_commands.proto:319-330` (oneof tags 18/19),
`common/v1/message.proto:47-54`. Perl `Workflow.pm:31-38,63,177-189`,
`Workflow/Commands.pm`, `Workflow/Runner.pm`,
`Common/SearchAttributeKey.pm` (add value_set/value_unset).

---

# Phase 8 — Scheduling (§25)

## 25. Schedules (v0.2, Phase 8)

A **purely client-side** feature — no workflow-runner, worker, or
activation changes. Three new `Client` methods, a `ScheduleHandle`
mirroring `WorkflowHandle`, a lazy list iterator mirroring
`WorkflowExecutionIterator`, and a flat `Temporalio::Schedule::*` data-class
tree (resolved decision: flat namespace, closer to Python than Ruby's
deep nesting; the umbrella `Temporalio::Schedule` re-exports constructors).
New files: `Client/ScheduleHandle.pm`, `Client/ScheduleListIterator.pm`,
`Schedule.pm` + `Schedule/{Schedule,Spec,Calendar,Range,Interval,State,
Policy,Action,Backfill,Update,Description,Info,ListDescription}.pm`,
`Exception/ScheduleAlreadyRunning.pm`.

### 25.1 Public API

```perl
my $h = $client->get_schedule_handle($id);             # no RPC
my $h = await $client->create_schedule($id, $schedule,
    trigger_immediately => 0, backfills => [], memo => undef,
    search_attributes => undef);                       # -> ScheduleHandle
my $it = $client->list_schedules($query, page_size => 1000);  # lazy iterator

# ScheduleHandle (mirrors WorkflowHandle; explicit id/client readers, 5.38 floor):
await $h->describe;                 # -> Schedule::Description
await $h->delete;
await $h->backfill(@backfills);     # >=1 required (PatchSchedule)
await $h->trigger(overlap => undef);
await $h->pause(note => 'Paused via Perl SDK');
await $h->unpause(note => 'Unpaused via Perl SDK');
await $h->update($updater);         # $updater: ($update_input) -> Schedule::Update|undef|Future
```

Resolved decisions: `backfills` (plural) on create; default pause/unpause
notes `"Paused via Perl SDK"`/`"Unpaused via Perl SDK"`; the action takes a
workflow **type-name string** only (coderef resolution lands with workflow
registration, not here).

**Data classes** (`feature 'class'`, kwargs; private `_to_proto`/`_from_proto`;
only `Schedule->_to_proto` and `Action::StartWorkflow->_to_proto` are async —
they encode payloads). Load-bearing proto remaps:

- `Schedule->new(action=>, spec=>, policy=>, state=>)` → proto field
  **`policies`** (plural) ↔ Perl `policy`.
- `Spec->new(calendars=>[], intervals=>[], cron_expressions=>[], skip=>[],
  start_at=>, end_at=>, jitter=>, time_zone_name=>)` — remaps
  calendars↔`structured_calendar`, cron_expressions↔`cron_string`,
  intervals↔`interval`, skip↔`exclude_structured_calendar`,
  time_zone_name↔`timezone_name`. On describe the server returns only
  structured/interval (cron compiles server-side), so `_from_proto` leaves
  `cron_expressions` empty.
- `Calendar->new(second=>,minute=>,hour=>,day_of_month=>,month=>,year=>,
  day_of_week=>,comment=>)` with `Range->new($start,$end=$start,$step=1)`.
  **Per-field default ranges are load-bearing** — an empty `second` means
  "never match", so the constructor MUST inject defaults (`second=[0]`,
  `day_of_month=[1..31]`, etc.). `Range` is inclusive/inclusive, step 1,
  passed verbatim (no +1).
- `Interval->new(every=>, offset=>)` → `interval`/`phase`.
- `State->new(note=>, paused=>0, limited_actions=>0, remaining_actions=>0)`
  → `note`↔`notes`.
- `Policy->new(overlap=>'skip', catchup_window=>365d, pause_on_failure=>0)`.
- `Action::StartWorkflow->new($type_name, args=>[], id=>, task_queue=>,
  execution_timeout=>, run_timeout=>, task_timeout=>, retry_policy=>,
  memo=>, search_attributes=>, headers=>, priority=>)` → wraps
  `NewWorkflowExecutionInfo`. `workflow_id_reuse_policy` and `cron_schedule`
  are INVALID in a schedule action — reject as unknown kwargs.
- `Backfill->new(start_at=>, end_at=>, overlap=>)` — write-only; `start_at`
  is **exclusive**, `end_at` inclusive.
- `Update->new(schedule=>, search_attributes=>)`; the updater receives
  `Update::Input->new(description=>)`.
- `OverlapPolicy` string→enum: `unspecified`0/`skip`1/`buffer_one`2/
  `buffer_all`3/`cancel_other`4/`terminate_other`5/`allow_all`6.

Read-side decode-only classes: `Description` (id, schedule, info, typed
search attributes, lazy memo, raw_description — **action workflow args held
as raw Payloads** for round-trip fidelity), `Info` (num_actions, recent/next
action times), `ListDescription` (lossy list view).

### 25.2 Behavioral contract

Every RPC funnels through `_rpc_call` (`service=>'workflow'`, `retry=>1`;
§7.5 error map).

- **create_schedule**: validate the `limited_actions`/`remaining_actions`
  invariant before any RPC (raise `Argument`); build `initial_patch` only if
  `trigger_immediately || @backfills` (trigger overlap comes from the
  schedule's OWN policy); `CreateScheduleRequest{schedule_id, schedule =>
  await _to_proto, initial_patch, memo, search_attributes, request_id}`;
  return a handle.
- **describe**: decode into `Description`; the returned schedule may differ
  from created (specs compiled); action args are NOT eagerly decoded (held
  raw so describe→modify→update re-emits identical payloads); schedule-level
  SAs decoded eagerly, memo lazily.
- **delete**: `DeleteScheduleRequest` has **no `request_id`**.
- **PatchSchedule ops** (backfill/trigger/pause/unpause) build a
  `PatchScheduleRequest` differing only in the `SchedulePatch`. `trigger`
  fires even while paused. `backfill` raises `Argument` if empty.
- **update($updater)**: internal describe → `Update::Input`; invoke the
  updater (may return a `Schedule::Update`, falsy, or a Future — await if
  Future); falsy → no RPC; else `UpdateScheduleRequest` replacing
  spec/action/policies/state completely; if `update->search_attributes` is
  **defined** (even empty) clear+re-encode SAs. **Single-shot** (resolved
  decision: no conflict-token retry loop — neither reference SDK implements
  it; carry the same TODO).
- **Action encoding**: `Action::StartWorkflow->_to_proto($client)` encodes
  each arg via the data converter (an already-`Payload` arg passes through),
  memo/header via the string-payload-map helpers, typed SAs via the SA
  encoder, timeouts via `_duration`. (Codec-context binding deferred to the
  interceptor/codec-context work, §27.)

### 25.3 Failure modes

- **Duplicate schedule id** → server `ALREADY_EXISTS`; `create_schedule`
  catches the §7.5-mapped error for `CreateSchedule` and re-raises
  **`Temporalio::Exception::ScheduleAlreadyRunning`** (new class). (Resolved:
  the re-map happens in `create_schedule`, not the §7.5 table.)
- **Schedule not found** → §7.5 `NotFound` (no schedule-specific subclass).
- **limited/remaining mismatch** or **empty backfill** → `Argument` before RPC.
- **Unknown kwargs** (incl. `workflow_id_reuse_policy`/`cron_schedule` on the
  action) → `Argument`.

### 25.4 Test scenarios

Integration (`sdk/t/integration/schedule.t`, skip without dev server;
filter scheduled runs by workflow **type**, not exact id). Unit
request-builder echoes where noted.

- **T-sched-1** `basic` — create/describe/list/update/delete; interval spec,
  `buffer_one` overlap; update mutates the action args (`arg1`→`arg2`).
- **T-sched-2** `backfill` — paused schedule, two backfill windows
  `allow_all`; poll until `num_actions==6`.
- **T-sched-3** `cron` — the compliance `cron` scenario tests the legacy
  per-workflow `cron_schedule` start option (map to `start_workflow`); **plus**
  a Perl-authored `ScheduleSpec.cron_expressions` round-trip (no compliance
  scenario exists for it).
- **T-sched-4** `duplicate_error` — second create with the same id →
  `ScheduleAlreadyRunning` (clean unit form via a stubbed ALREADY_EXISTS).
- **T-sched-5** `pause` — pure-client; assert paused/note after each
  pause/unpause incl. the exact default notes.
- **T-sched-6** `trigger` — trigger twice (paused); poll until `num_actions==2`.
- **T-sched-7** `list_matching_times` — Perl-authored (no compliance
  scenario); assert projected fire times.
- **T-sched-unit** — Range/Calendar inclusivity (Range inclusive/inclusive
  no +1; default ranges injected; the three coexisting inclusivity rules —
  Range, ScheduleSpec.start_time inclusive, Backfill.start_time exclusive).

### 25.5 Reference anchors (MUST-match)

sdk-python `client/_schedule.py:67-1604`, `client/_client.py:2669-2736`,
`client/_impl.py:1165-1378`. sdk-ruby `client/schedule.rb`,
`client/schedule_handle.rb`, `client.rb:680-723`,
`internal/client/implementation.rb:616-808`. Protos
`schedule/v1/message.proto`, `enums/v1/schedule.proto:15-38`,
`workflow/v1/message.proto:425-455` (NewWorkflowExecutionInfo),
`workflowservice/v1/request_response.proto:1351-1488`. Perl: `Client.pm`
(`_rpc_call`, `_encode_string_payload_map`, `_duration`,
`_coerce_search_attributes`, `_new_uuid`, policy-enum pattern),
`WorkflowHandle.pm` + `WorkflowExecutionIterator.pm` (templates).

---

# Phase 9 — Nexus (§26)

## 26. Nexus (v0.2, Phase 9)

> **Experimental** in every reference SDK; this contract inherits the
> "may change" caveat.

Nexus connects two namespaces (or a namespace and an external service)
through a server-registered **endpoint**. A caller workflow invokes a named
**operation** on a **service** at an endpoint; a handler worker serves it.
Operations are **sync** (handler returns inline; Scheduled→Completed, no
Started event) or **async** (handler starts backing work — typically a
workflow — returns an operation token; Scheduled→Started→Completed). Both
caller and handler sides are required (user decision). Resolved forks: the
handler side follows sdk-python alone (Ruby runs it in Go core) and
**reimplements the small `nexusrpc` slice natively** under
`Temporalio::Nexus::*` (F2); definitions use the **attribute pattern**
(`:NexusService`/`:SyncOperation`/`:WorkflowRunOperation`, F3); **no
endpoint-creation client API** (endpoints are server/operator-managed,
the name is a caller string input, F4); `cancellation_type` default
**`wait_cancellation_completed`** (F5, = Nexus proto zero); explicit
`$handle->cancel` (F6, parity with §18).

### 26.1 Public API — caller side

Files: `Workflow.pm` (`create_nexus_client`), `Workflow/NexusClient.pm`
(new), `Workflow/NexusOperationHandle.pm` (new), `Workflow/Commands.pm`,
`Workflow/Runner.pm`.

```perl
my $nc = Temporalio::Workflow::create_nexus_client(
    endpoint => $endpoint, service => 'test-service');

my $handle = await $nc->start_operation(
    'say-hello', 'world',                  # operation name + SINGLE arg (one input Payload)
    schedule_to_close_timeout => undef,    # seconds → Duration
    schedule_to_start_timeout => undef,
    start_to_close_timeout    => undef,
    cancellation_type         => 'wait_cancellation_completed',
    summary                   => undef,    # → user_metadata
    headers                   => {},       # → nexus_header (string→string, NOT Temporal headers)
);
my $result = await $handle->result;

my $result = await $nc->execute_operation('say-hello', 'world', schedule_to_close_timeout => 60);
```

`create_nexus_client` returns a `NexusClient` bound to endpoint+service
(never instantiated directly). The proto carries a **single** `input`
Payload, so `start_operation` takes one positional `$arg` (not `args`).
`NexusOperationHandle` (constructed only by `start_operation`):
`operation_token` (async ops: token; sync ops: undef), `await
$handle->result` (idempotent; awaiting the handle == `->result`),
`$handle->cancel`. Cancellation-type strings →
`NexusOperationCancellationType`: `wait_cancellation_completed`0 (default),
`abandon`1, `try_cancel`2, `wait_cancellation_requested`3.

### 26.2 Public API — handler side (Python-reference, native reimplementation)

Files: `Nexus.pm` (umbrella + handler context helpers), `Nexus/Definition.pm`
(service/operation definition base + attribute handlers),
`Nexus/OperationContext.pm` (`StartOperationContext`,
`CancelOperationContext`, `WorkflowRunOperationContext`),
`Nexus/OperationResult.pm` (`StartOperationResultSync`/`Async`),
`Nexus/WorkflowHandle.pm` (operation-token encode/decode),
`Worker/NexusDispatcher.pm`, `Worker/NexusRegistry.pm`.

```perl
class My::NexusService :isa(Temporalio::Nexus::Definition) :NexusService('test-service') {
    method say_hello :SyncOperation('say-hello') ($ctx, $name) { return "Hello, $name!" }

    method echo :WorkflowRunOperation('echo') ($ctx, $input) {
        return await $ctx->start_workflow('EchoHandlerWorkflow', $input, id => ...);
    }
}

my $worker = Temporalio::Worker->new(..., nexus_services => [ My::NexusService->new ]);
```

`:NexusService($name)` registers the service (default: class name).
`:SyncOperation($name)` returns the result directly (dispatcher wraps in
`StartOperationResultSync`; sig `($ctx, $input)`, `$ctx` a
`StartOperationContext`). `:WorkflowRunOperation($name)` must call
`$ctx->start_workflow(...)` and return a `Nexus::WorkflowHandle` (dispatcher
→ `StartOperationResultAsync{operation_token}`; `$ctx` a
`WorkflowRunOperationContext` adding `start_workflow` with the full
client-start kwargs). The four §10.1 attribute constraints apply. Handler
context module functions: `Temporalio::Nexus::info`/`::client`/`::logger`/
`::in_operation`/`::is_worker_shutdown`.

### 26.3 Behavioral contract

**Caller (mirrors §18 two-stage).** Separate seq space
(`$nexus_operation_seq_counter`). `start_operation` allocates seq; converts
the single `arg`→`input` Payload, the three timeouts→Duration,
`cancellation_type`→enum, `summary`→user_metadata (all before buffering);
emits one `ScheduleNexusOperation` (oneof arm 21); registers a start Future
in `%pending_nexus_operation_starts{seq}` and a result Future (in a
`NexusOperationHandle`) in `%pending_nexus_operations{seq}` + a cancel
callback; returns the start Future. A pre-scheduled cancel raises
`Cancelled` immediately.

- **`ResolveNexusOperationStart`**: `operation_token`→async, store token,
  `->done` start (don't pop — result job follows); `started_sync`→sync,
  token undef, `->done` start, result job is in the **same activation**;
  `failed`→pop, `->fail` start (no result job follows).
- **`ResolveNexusOperation`**: look up by seq (unknown→non-determinism);
  `completed`→`->done` converted result; `failed`/`cancelled`/`timed_out`→
  `->fail` (mapped, §26.4); pop the seq.
- **Sync vs async** is the key compliance distinction: sync = `started_sync`
  + same-activation completed (no Started event server-side); async =
  `operation_token` start then a later resolve.
- **Cancellation**: `$handle->cancel` (or `CancelWorkflow` propagating —
  extend `_apply_cancel_workflow`) emits `RequestCancelNexusOperation{seq}`
  only if still pending, except under `abandon`. `result` waits under a
  detached cancellation so requesting cancel doesn't interrupt the wait.

**Handler (mirrors Python `_NexusWorker`).** `NexusDispatcher` polls Nexus
tasks (`poll_nexus_task`) on core and drains results on the main IO::Async
thread via the existing trampoline-queue path (user code never runs on a
Tokio thread). A `NexusTask` is a server `task` or a `cancel_task`
(core-abort); track running tasks by `task_token`. Start-operation task →
build `StartOperationContext`, run the registered operation: sync return →
`StartOperationResponse.Sync{payload}`; `WorkflowHandle` return →
`StartOperationResponse.Async{operation_token}`. Cancel-operation task →
decode token → cancel backing workflow. `cancel_task` → cancel the tracked
task, ack. Completion sends are shielded from cancellation (never dropped or
shutdown hangs); shutdown drains remaining tasks then waits for running ones.

### 26.4 Failure modes

**Caller** → `Temporalio::Exception::NexusOperation` (existing class) whose
`cause` is the mapped failure: `result{failed}`→`Application`;
`{timed_out}`→`Timeout`; `{cancelled}`→`Cancelled`; start `{failed}` fails
the start await (no result job). Carries endpoint/service/operation/
operation_token/scheduled_event_id. Unknown-seq resolve → non-determinism.

**Handler** → `Temporalio::Exception::NexusHandler` (existing class)
carrying a Nexus `type` + `retry_behavior`. The dispatcher's error mapping
mirrors Python `_exception_to_handler_error`: HandlerError passes through;
`Application`(non_retryable)→`INTERNAL`; `WorkflowAlreadyStarted`→`INTERNAL`
non-retryable; **gRPC status→Nexus type is a MUST-match table**
(INVALID_ARGUMENT→BAD_REQUEST, NOT_FOUND→NOT_FOUND,
RESOURCE_EXHAUSTED→RESOURCE_EXHAUSTED, UNIMPLEMENTED→NOT_IMPLEMENTED,
DEADLINE_EXCEEDED→UPSTREAM_TIMEOUT, UNAVAILABLE/ABORTED→UNAVAILABLE, else
INTERNAL); else→`INTERNAL`. A handler `OperationError` (op failed/cancelled,
not infra) produces a failure-carrying `StartOperationResponse`
(`CANCELED`→`Cancelled`, `FAILED`→`Application`).

### 26.5 Test scenarios

Caller (replay, `sdk/t/replay/nexus.t`):

- **T-nexus-1** — `start_operation` emits one `ScheduleNexusOperation`
  (seq 1, endpoint/service/operation, single converted `input`,
  `cancellation_type=0`, summary→user_metadata, converted timeouts).
- **T-nexus-2** — `started_sync` + same-activation `completed` resolves
  `execute_operation` (`operation_token` undef); the **primary sync_success**
  case (`"Hello, world!"`, no Started event).
- **T-nexus-3/4** — `operation_token` start resolves the handle; later
  `completed` resumes a parked `execute`.
- **T-nexus-5/6** — `failed`→`NexusOperation`/`Application`;
  `timed_out`→`Timeout`; `cancelled`→`Cancelled`.
- **T-nexus-7** — start `failed` fails the start await; no result job.
- **T-nexus-8** — `$handle->cancel` emits `RequestCancelNexusOperation`;
  `abandon` emits none; pre-scheduled cancel raises `Cancelled`.
- **T-nexus-9** — unknown-seq resolve → non-determinism.
- **T-nexus-10** *(integration)* — full `sync_success` against a live worker
  + endpoint; assert `NexusOperationScheduled`+`Completed`, NO `Started`.

Handler (Python-reference):

- **T-nexus-11** — `:NexusService`/`:SyncOperation` register in the registry
  (four §10.1 constraints hold).
- **T-nexus-12/13** *(integration)* — sync-op start →
  `StartOperationResponse.Sync{payload}`; workflow-run-op start → `Async
  {operation_token}` and a cancel task cancels the backing workflow.
- **T-nexus-14** — handler error → `NexusHandler` with the right `type`
  (spot-check the gRPC→Nexus MUST-match table); `OperationError`
  (FAILED/CANCELED) → failure-carrying `StartOperationResponse`.

### 26.6 Reference anchors (MUST-match)

Caller: sdk-python `workflow/_nexus.py:28-500`; sdk-ruby
`workflow/nexus_client.rb`, `workflow/nexus_operation_handle.rb`,
`internal/worker/workflow_instance/outbound_implementation.rb:435-512`.
Handler (Python-only): `worker/_nexus.py:99-582`, `nexus/_decorators.py`,
`nexus/_operation_handlers.py:59-114`, `nexus/_operation_context.py:76-470`,
`worker/_worker.py:103,162`, `tests/nexus/test_standalone_operations.py:133-168`.
Protos: `workflow_commands.proto:358,401` (Schedule/RequestCancel, arms
21/22), `workflow_activation.proto:352,370` (ResolveStart/Resolve),
`core/nexus/nexus.proto:13,23,42,84`. Existing Perl: `Exception/NexusOperation.pm`,
`Exception/NexusHandler.pm`, §18 (caller template),
`Worker/ActivityDispatcher.pm` + `Activity/Definition.pm` (handler analogs).
