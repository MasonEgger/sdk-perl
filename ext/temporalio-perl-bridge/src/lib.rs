// ABOUTME: Rust callback shim for the Temporalio Perl SDK (spec section 3).
// ABOUTME: Trampolines enqueue completions and signal an fd; never touch Perl.

use std::ffi::{c_char, c_void};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicPtr, AtomicU64, AtomicUsize, Ordering};

use crossbeam_queue::SegQueue;

/// Opaque borrow of `temporal-sdk-core-c-bridge`'s `TemporalCoreByteArray`.
/// The shim never dereferences these — pointers pass through to Perl, which
/// frees them via `temporal_core_byte_array_free`.
#[repr(C)]
pub struct TemporalCoreByteArray {
    _private: [u8; 0],
}

/// Opaque borrow of `TemporalCoreConnection` (client connect success handle).
#[repr(C)]
pub struct TemporalCoreConnection {
    _private: [u8; 0],
}

/// Opaque borrow of `TemporalCoreEphemeralServer` (server start success handle).
#[repr(C)]
pub struct TemporalCoreEphemeralServer {
    _private: [u8; 0],
}

/// Opaque borrow of sdk-core-c-bridge's `ForwardedLog`. The shim never
/// dereferences this — it only passes the pointer back to core's
/// `temporal_core_forwarded_log_*` accessors, which are valid only for the
/// duration of the `forward_to` callback (the log is freed the instant the
/// callback returns).
#[repr(C)]
pub struct TemporalCoreForwardedLog {
    _private: [u8; 0],
}

/// `kind` discriminator values, 1..6 in spec section 3 trampoline order, plus
/// the kind-7 log-forwarding entry (spec section 28.1). Kind 7 differs from
/// 1..6: it carries no `callback_id` (no pending Future) and owns its buffers
/// shim-side, freed via `temporalio_perl_bridge_forwarded_log_free`.
pub const TEMPORALIO_PERL_BRIDGE_KIND_WORKER_POLL: u8 = 1;
pub const TEMPORALIO_PERL_BRIDGE_KIND_WORKER: u8 = 2;
pub const TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_CONNECT: u8 = 3;
pub const TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_RPC_CALL: u8 = 4;
pub const TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_START: u8 = 5;
pub const TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_SHUTDOWN: u8 = 6;
pub const TEMPORALIO_PERL_BRIDGE_KIND_FORWARDED_LOG: u8 = 7;

/// One queued completion. `kind` discriminates which trampoline fired (1..6)
/// and therefore which fields are meaningful. ByteArray pointers must be
/// freed by the Perl side via `temporal_core_byte_array_free`.
#[repr(C)]
pub struct TemporalioPerlBridgeEntry {
    pub callback_id: u64,
    /// Tagged union discriminator, 1..6 in trampoline declaration order.
    pub kind: u8,
    /// Common: success / fail byte arrays (null when absent).
    pub success_ba: *const TemporalCoreByteArray,
    pub fail_ba: *const TemporalCoreByteArray,
    /// Client connect / ephemeral server start success handle.
    pub success_handle: *mut c_void,
    /// RPC call extras (fail_ba carries the failure_message). For a kind-7
    /// forwarded-log entry, `rpc_status_code` carries the forwarded log level
    /// (0..4 = Trace..Error).
    pub rpc_status_code: u32,
    pub rpc_failure_details: *const TemporalCoreByteArray,
    /// Ephemeral server start target string.
    pub ephemeral_target: *const TemporalCoreByteArray,
    /// Kind-7 forwarded-log payload (spec section 28.1). These three buffers
    /// are deep copies owned by the shim (NUL-terminated C strings), freed by
    /// `temporalio_perl_bridge_forwarded_log_free` after the Perl drain reads
    /// them, or by `Entry::drop` for undrained entries at queue free. They are
    /// null for every kind other than 7.
    pub log_target: *mut c_char,
    pub log_message: *mut c_char,
    pub log_fields_json: *mut c_char,
    /// Kind-7 forwarded-log timestamp (milliseconds since the Unix epoch).
    pub log_timestamp_ms: u64,
}

// Entries hold raw pointers handed to us by sdk-core on Tokio threads; they
// are inert data in transit to the single Perl-side consumer.
unsafe impl Send for TemporalioPerlBridgeEntry {}

impl TemporalioPerlBridgeEntry {
    const fn empty() -> Self {
        Self {
            callback_id: 0,
            kind: 0,
            success_ba: ptr::null(),
            fail_ba: ptr::null(),
            success_handle: ptr::null_mut(),
            rpc_status_code: 0,
            rpc_failure_details: ptr::null(),
            ephemeral_target: ptr::null(),
            log_target: ptr::null_mut(),
            log_message: ptr::null_mut(),
            log_fields_json: ptr::null_mut(),
            log_timestamp_ms: 0,
        }
    }

    /// Free the shim-owned kind-7 log buffers, if any, leaving them null.
    /// Idempotent: a second call is a no-op (null pointers). Called by
    /// `temporalio_perl_bridge_forwarded_log_free` after the Perl drain reads
    /// the strings, and by `Drop` for undrained entries at queue free.
    fn free_log_buffers(&mut self) {
        for slot in [
            &mut self.log_target,
            &mut self.log_message,
            &mut self.log_fields_json,
        ] {
            if !slot.is_null() {
                // SAFETY: every non-null log_* pointer is a CString::into_raw
                // allocation from `forwarded_log_trampoline`, reclaimed once.
                drop(unsafe { std::ffi::CString::from_raw(*slot) });
                *slot = ptr::null_mut();
            }
        }
    }
}

impl Drop for TemporalioPerlBridgeEntry {
    fn drop(&mut self) {
        // Only kind-7 entries own heap buffers; for kinds 1..6 every log_*
        // pointer is null and this is a no-op. Drained kind-7 entries are
        // moved into the Perl drain buffer with `ptr::write` (which never
        // runs Drop), so this fires only for entries still queued when the
        // SegQueue is dropped — the shutdown "free undrained" path.
        self.free_log_buffers();
    }
}

/// Thread-safe completion queue: an unbounded `SegQueue` plus the signal fd.
/// One allocation per `Temporalio::Core::Runtime` instance.
pub struct TemporalioPerlBridgeQueue {
    entries: SegQueue<TemporalioPerlBridgeEntry>,
    signal_fd: AtomicI32,
    /// True when `signal_fd` is a pipe write-end (FIFO): signal one byte per
    /// push and leave draining the read end to the Perl side. False means
    /// eventfd: signal a u64 1 and drain the counter in `queue_drain`.
    signal_is_fifo: bool,
}

impl TemporalioPerlBridgeQueue {
    /// Push one entry, then signal the fd once. A failed signal write is
    /// logged (unless EAGAIN) and dropped, never retried — the entry stays
    /// queued and the drain loop picks up the backlog on the next signal.
    fn push(&self, entry: TemporalioPerlBridgeEntry) {
        self.entries.push(entry);
        self.signal();
    }

    fn signal(&self) {
        let fd = self.signal_fd.load(Ordering::Relaxed);
        if fd < 0 {
            return;
        }
        let res = if self.signal_is_fifo {
            let byte = 1u8;
            unsafe { libc::write(fd, ptr::from_ref(&byte).cast::<c_void>(), 1) }
        } else {
            let val = 1u64;
            unsafe { libc::write(fd, ptr::from_ref(&val).cast::<c_void>(), 8) }
        };
        if res < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() != std::io::ErrorKind::WouldBlock {
                eprintln!(
                    "temporalio-perl-bridge: signal fd {fd} write failed (signal dropped): {err}"
                );
            }
        }
    }

    /// Clear the eventfd counter so subsequent pushes signal again. Called
    /// BEFORE popping entries: any signal that lands after the clear has its
    /// entry already queued (push happens-before signal), so no wakeup is
    /// lost. For pipes the Perl side drains the read end itself; the shim
    /// only holds the write end. The fd must be non-blocking.
    fn clear_signal(&self) {
        if self.signal_is_fifo {
            return;
        }
        let fd = self.signal_fd.load(Ordering::Relaxed);
        if fd < 0 {
            return;
        }
        let mut counter = 0u64;
        unsafe { libc::read(fd, ptr::from_mut(&mut counter).cast::<c_void>(), 8) };
    }
}

fn fd_is_fifo(fd: i32) -> bool {
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut st) } != 0 {
        return false;
    }
    (st.st_mode & libc::S_IFMT) == libc::S_IFIFO
}

/// The single-shot (queue, callback_id) pair passed as `user_data` to
/// sdk-core-c-bridge async calls. Allocated by `user_data_new`, freed by the
/// trampoline after it enqueues the completion entry.
struct UserData {
    queue: *const TemporalioPerlBridgeQueue,
    callback_id: u64,
}

/// Generic completion path shared by all six trampolines: take ownership of
/// the user_data pair, build the entry with its callback_id, push + signal
/// on the pair's queue, free the pair (single-shot).
unsafe fn complete(
    user_data: *mut c_void,
    build: impl FnOnce(u64) -> TemporalioPerlBridgeEntry,
) {
    if user_data.is_null() {
        return;
    }
    let pair = Box::from_raw(user_data.cast::<UserData>());
    let queue = &*pair.queue;
    queue.push(build(pair.callback_id));
    // `pair` drops here — the single-shot free.
}

// --- Log forwarding (spec section 28.1, kind 7) -----------------------------
//
// Core's `forward_to` callback (a `TemporalCoreForwardedLogCallback`) takes no
// user_data, so the trampoline cannot route via a (queue, callback_id) pair.
// Instead a process-global registry holds the single forwarding queue; the
// trampoline deep-copies the log's fields (the `ForwardedLog` is freed the
// instant the callback returns) into a shim-owned kind-7 entry and pushes it
// there. `Runtime->new` raises Argument if a second runtime requests
// forwarding while one is active (per-id routing deferred, spec section 28.1).

/// A borrowed byte slice as returned by core's forwarded-log accessors,
/// matching `TemporalCoreByteArrayRef` (data may be null/zero-length).
#[repr(C)]
pub struct ForwardedLogByteArrayRef {
    pub data: *const u8,
    pub size: usize,
}

// sdk-core-c-bridge's forwarded-log accessor signatures. The shim does NOT
// declare these as undefined externs (FFI::Platypus loads each library
// RTLD_LOCAL, so the shim's undefined symbols would not resolve against the
// separately loaded core lib). Instead the Perl side — which has its own
// FFI handle on the core lib — passes the four accessor function pointers to
// `forwarding_register`, and the trampoline calls through them.
type LogRefAccessor =
    unsafe extern "C" fn(*const TemporalCoreForwardedLog) -> ForwardedLogByteArrayRef;
type LogTimestampAccessor = unsafe extern "C" fn(*const TemporalCoreForwardedLog) -> u64;

/// The accessor function pointers core uses to read a `ForwardedLog`, supplied
/// by Perl at registration so the shim never hard-links the core bridge.
struct LogAccessors {
    target: LogRefAccessor,
    message: LogRefAccessor,
    timestamp_millis: LogTimestampAccessor,
    fields_json: LogRefAccessor,
}

/// The process-global forwarding queue (null when no runtime forwards logs).
static FORWARDING_QUEUE: AtomicPtr<TemporalioPerlBridgeQueue> = AtomicPtr::new(ptr::null_mut());

/// The forwarding accessor table. Set under the registry claim, read in the
/// trampoline. A `Box<LogAccessors>` leaked into a raw pointer; replaced on
/// each register, never freed (the table is tiny and process-lifetime).
static FORWARDING_ACCESSORS: AtomicPtr<LogAccessors> = AtomicPtr::new(ptr::null_mut());

/// True while a runtime owns the forwarding registry. Distinct from the queue
/// pointer being non-null so `Runtime->new`'s "second forwarder" guard is a
/// single atomic compare-and-set.
static FORWARDING_ACTIVE: AtomicBool = AtomicBool::new(false);

/// Claim the process-global forwarding registry for `q`, recording the four
/// core accessor function pointers (passed as opaque from Perl). Returns true
/// on success, false if a runtime already forwards logs (the caller raises
/// Argument). The compare-and-set on the active flag makes the claim race-free
/// across runtimes constructed concurrently.
///
/// # Safety
/// The four pointers must be the live `temporal_core_forwarded_log_*` symbols
/// from the loaded core bridge, valid for the life of the registration.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_forwarding_register(
    q: *mut TemporalioPerlBridgeQueue,
    target: *const c_void,
    message: *const c_void,
    timestamp_millis: *const c_void,
    fields_json: *const c_void,
) -> bool {
    if FORWARDING_ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return false;
    }
    let accessors = Box::new(LogAccessors {
        target: std::mem::transmute::<*const c_void, LogRefAccessor>(target),
        message: std::mem::transmute::<*const c_void, LogRefAccessor>(message),
        timestamp_millis: std::mem::transmute::<*const c_void, LogTimestampAccessor>(
            timestamp_millis,
        ),
        fields_json: std::mem::transmute::<*const c_void, LogRefAccessor>(fields_json),
    });
    let old = FORWARDING_ACCESSORS.swap(Box::into_raw(accessors), Ordering::AcqRel);
    if !old.is_null() {
        drop(Box::from_raw(old));
    }
    FORWARDING_QUEUE.store(q, Ordering::Release);
    true
}

/// Release the forwarding registry held by `q`. A no-op unless `q` is the
/// currently registered queue (so a non-forwarding runtime's shutdown never
/// clears another runtime's registration). Called from `Runtime->shutdown`
/// before the queue is freed.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_forwarding_unregister(
    q: *mut TemporalioPerlBridgeQueue,
) {
    if FORWARDING_QUEUE.load(Ordering::Acquire) == q {
        FORWARDING_QUEUE.store(ptr::null_mut(), Ordering::Release);
        let old = FORWARDING_ACCESSORS.swap(ptr::null_mut(), Ordering::AcqRel);
        if !old.is_null() {
            // SAFETY: every non-null FORWARDING_ACCESSORS value is a leaked
            // Box from a register call, reclaimed once here.
            drop(unsafe { Box::from_raw(old) });
        }
        FORWARDING_ACTIVE.store(false, Ordering::Release);
    }
}

/// Deep-copy one accessor's borrowed bytes into a shim-owned NUL-terminated C
/// string. Interior NULs are stripped (CString rejects them) so a pathological
/// field can never null-terminate early; the Perl side reads the bytes as
/// UTF-8. A null/empty ref yields an empty string, never a null pointer, so
/// the drain always has a readable target/message.
fn copy_ref_to_cstring(r: &ForwardedLogByteArrayRef) -> *mut c_char {
    let bytes: Vec<u8> = if r.data.is_null() || r.size == 0 {
        Vec::new()
    } else {
        // SAFETY: core guarantees data/size describe a valid borrow for the
        // life of the callback; we copy out before returning.
        unsafe { std::slice::from_raw_parts(r.data, r.size) }
            .iter()
            .copied()
            .filter(|b| *b != 0)
            .collect()
    };
    // unwrap is safe: interior NULs were filtered above.
    std::ffi::CString::new(bytes).unwrap().into_raw()
}

/// Trampoline for core's `TemporalCoreForwardedLogCallback` (kind 7). Reads
/// the log's target/message/timestamp/fields-JSON via core's accessors,
/// deep-copies each string into shim-owned buffers, and pushes a kind-7 entry
/// onto the registered forwarding queue. A null registry (forwarding torn down
/// mid-flight) drops the log. No `user_data`: routing is via the registry.
///
/// # Safety
/// `log` must be the valid `ForwardedLog` pointer core passes for the life of
/// this call; it must not be used after the callback returns.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_forwarded_log_callback(
    level: u32,
    log: *const TemporalCoreForwardedLog,
) {
    let queue = FORWARDING_QUEUE.load(Ordering::Acquire);
    let accessors = FORWARDING_ACCESSORS.load(Ordering::Acquire);
    if queue.is_null() || accessors.is_null() || log.is_null() {
        return;
    }
    let accessors = &*accessors;
    let target = copy_ref_to_cstring(&(accessors.target)(log));
    let message = copy_ref_to_cstring(&(accessors.message)(log));
    let fields_json = copy_ref_to_cstring(&(accessors.fields_json)(log));
    let timestamp_ms = (accessors.timestamp_millis)(log);
    (*queue).push(TemporalioPerlBridgeEntry {
        kind: TEMPORALIO_PERL_BRIDGE_KIND_FORWARDED_LOG,
        rpc_status_code: level,
        log_target: target,
        log_message: message,
        log_fields_json: fields_json,
        log_timestamp_ms: timestamp_ms,
        ..TemporalioPerlBridgeEntry::empty()
    });
}

/// Address of the forwarded-log trampoline, for the `forward_to` slot of
/// `TemporalCoreLoggingOptions`.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_forwarded_log_callback_ptr() -> *mut c_void {
    temporalio_perl_bridge_forwarded_log_callback as *mut c_void
}

/// Free the shim-owned kind-7 log buffers of a drained entry. Called by the
/// Perl drain after it copies the target/message/fields strings out of the
/// entry. Idempotent (null pointers no-op); undrained entries are freed by
/// `Entry::drop` at queue free instead.
///
/// # Safety
/// `entry` must point at a drained `TemporalioPerlBridgeEntry` written by
/// `temporalio_perl_bridge_queue_drain`, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_forwarded_log_free(
    entry: *mut TemporalioPerlBridgeEntry,
) {
    if !entry.is_null() {
        (*entry).free_log_buffers();
    }
}

// --- Custom metric meters (spec section 28.2) -------------------------------
//
// Core's `MetricsOptions.custom_meter` is a `TemporalCoreCustomMetricMeter`,
// eight function pointers core invokes for every metric create and record. The
// callbacks fire on ARBITRARY core threads with synchronous returns (header
// :436-440), which collides with the "never touch Perl off the main thread"
// rule. The resolution (spec section 28.2, hybrid):
//
//   * `metric_record_integer/float/duration` AGGREGATE in this shim — pure
//     Rust, applied on the core thread with zero Perl contact. Records are
//     bucketed by (metric id, attribute-set id) into a Rust table; the Perl
//     meter pulls a snapshot on the main-thread drain (re-implementing the
//     buffer the C header lacks, never dropping a record).
//   * `metric_new`/`attributes_new`/`metric_free`/`attributes_free`/
//     `meter_free` are MAIN-THREAD-MARSHALLED — they are rare and must run a
//     Perl method. The trampoline parks a request, signals the fd, and blocks
//     the core thread on a condvar until the Perl drain runs the method and
//     posts the result back.
//
// Reentrancy spike (spec section 28.2, M3): the header does not exclude the
// CALLING thread, so core can invoke `metric_new` synchronously while the main
// thread is already inside a bridge FFI call (metric creation during worker
// construction). If the marshalling path blocked on a condvar that only the
// main-thread drain can satisfy, that would self-deadlock. The trampoline
// therefore records the registering (main) thread id and, when a marshalled
// callback fires ON that thread, runs the Perl request INLINE via a reentrant
// callback supplied by Perl (no fd signal, no condvar). The aggregation path
// is pure Rust and never at risk.

/// Handle ids are non-zero so a returned `*const c_void` is never null (core
/// treats a null metric/attributes handle as "disabled"). Zero is the sentinel
/// for "Perl returned undef / disabled".
fn id_to_handle(id: u64) -> *const c_void {
    id as *const c_void
}

fn handle_to_id(h: *const c_void) -> u64 {
    h as u64
}

/// Which marshalled meter request the drain must run. The Perl side switches on
/// this tag; the body fields carry the request's payload (see `MeterRequest`).
pub const TEMPORALIO_PERL_BRIDGE_METER_REQ_METRIC_NEW: u8 = 1;
pub const TEMPORALIO_PERL_BRIDGE_METER_REQ_ATTRIBUTES_NEW: u8 = 2;
pub const TEMPORALIO_PERL_BRIDGE_METER_REQ_METRIC_FREE: u8 = 3;
pub const TEMPORALIO_PERL_BRIDGE_METER_REQ_ATTRIBUTES_FREE: u8 = 4;
pub const TEMPORALIO_PERL_BRIDGE_METER_REQ_METER_FREE: u8 = 5;

/// One decoded attribute, value tagged by `value_type` (1=String, 2=Int,
/// 3=Float, 4=Bool — `TemporalCoreMetricAttributeValueType`). Owned `String`
/// copies so the request outlives the core-borrowed attribute array.
#[derive(Clone)]
struct MeterAttribute {
    key: String,
    value_type: i32,
    string_value: String,
    int_value: i64,
    float_value: f64,
    bool_value: bool,
}

/// A parked create/free request the main-thread drain runs. For create requests
/// (`metric_new`/`attributes_new`) the shim has already allocated `new_id` (the
/// handle returned to core); the drain runs the Perl method and binds `new_id`
/// to the resulting Perl object. For free requests `free_id` is the handle to
/// release.
struct MeterRequest {
    tag: u8,
    /// Shim-allocated handle id for create requests (0 for free requests).
    new_id: u64,
    // metric_new
    name: String,
    description: String,
    unit: String,
    kind: i32,
    // attributes_new
    append_from_id: u64,
    attributes: Vec<MeterAttribute>,
    // metric_free / attributes_free
    free_id: u64,
}

/// One bucketed record snapshot the Perl meter pulls on drain: which metric and
/// attribute set, the record kind (1=integer, 2=float, 3=duration), and the
/// summed value. Floats and integers share `value` (f64) — integer/duration
/// records sum as i64 but are widened for the single snapshot shape, which is
/// exact for the magnitudes metrics produce.
#[repr(C)]
pub struct TemporalioPerlBridgeMeterRecord {
    pub metric_id: u64,
    pub attributes_id: u64,
    /// 1 = integer, 2 = float, 3 = duration (ms).
    pub record_kind: u8,
    pub value: f64,
    /// Number of record calls folded into `value` (for histogram/gauge the
    /// Perl meter may want the count; counters only need the sum).
    pub count: u64,
}

unsafe impl Send for TemporalioPerlBridgeMeterRecord {}

/// The process-global custom-meter registry. One per runtime carrying a custom
/// meter; the "only one custom meter" rule is enforced Perl-side (extended
/// T-rt-4) and by the compare-and-set on `active`.
///
/// Resolved reentrancy design (spec section 28.2 spike, M3). The meter
/// callbacks fire on arbitrary core threads — including, for `metric_new` /
/// `attributes_new` during worker construction, the MAIN thread while it is
/// already inside a bridge FFI call. Neither blocking on a main-thread drain
/// (self-deadlock) nor calling Perl synchronously from the trampoline (nested
/// FFI-closure re-entry corrupts libffi's state on repeated calls) is safe. The
/// shim therefore NEVER blocks and NEVER calls Perl from a callback: it
/// allocates the handle id ITSELF, parks a create/free request on a queue, and
/// returns the id immediately. The main-thread drain later runs the Perl
/// `create_metric`/`new_attributes`/free, binding the id to the Perl object.
/// Records arriving before the bind aggregate under the id and apply once the
/// bind lands (never dropped). This is thread-agnostic: the same path is
/// correct on the main thread, a Tokio thread, or reentrantly.
struct MeterRegistry {
    /// Signals the runtime's wakeup fd when a request is parked so the
    /// IO::Async drain runs. Borrowed; never freed here.
    queue: *const TemporalioPerlBridgeQueue,
    /// Monotonic handle-id source (metrics and attribute sets share the space;
    /// ids are opaque to core, never null so a returned handle is never null).
    next_id: std::sync::atomic::AtomicU64,
    /// Parked create/free requests, drained on the main thread (FIFO).
    requests: std::sync::Mutex<std::collections::VecDeque<MeterRequest>>,
    /// Aggregation table: (metric id, attributes id) -> (kind, sum, count).
    /// Pure Rust; written on core threads, drained on the main thread.
    records: std::sync::Mutex<std::collections::HashMap<(u64, u64), (u8, f64, u64)>>,
}

unsafe impl Send for MeterRegistry {}
unsafe impl Sync for MeterRegistry {}

static METER_REGISTRY: AtomicPtr<MeterRegistry> = AtomicPtr::new(ptr::null_mut());
static METER_ACTIVE: AtomicBool = AtomicBool::new(false);

impl MeterRegistry {
    /// Allocate a fresh non-null handle id.
    fn alloc_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::AcqRel) + 1
    }

    /// Park a create/free request and wake the drain. Never blocks, never calls
    /// Perl. For create requests the caller has already filled `new_id`.
    fn park(&self, req: MeterRequest) {
        {
            let mut q = self.requests.lock().unwrap();
            q.push_back(req);
        }
        self.signal();
    }

    fn signal(&self) {
        if self.queue.is_null() {
            return;
        }
        // SAFETY: queue is a live borrow for the registry's lifetime.
        unsafe { (*self.queue).signal() };
    }

    /// Fold one record into the aggregation table on the calling core thread.
    fn record(&self, metric_id: u64, attributes_id: u64, record_kind: u8, value: f64) {
        let mut table = self.records.lock().unwrap();
        let entry = table
            .entry((metric_id, attributes_id))
            .or_insert((record_kind, 0.0, 0));
        entry.0 = record_kind;
        entry.1 += value;
        entry.2 += 1;
    }
}

fn meter_registry() -> Option<&'static MeterRegistry> {
    let p = METER_REGISTRY.load(Ordering::Acquire);
    if p.is_null() {
        None
    } else {
        // SAFETY: a non-null registry pointer is a leaked Box live until
        // unregister, which only the owning runtime calls after core is freed.
        Some(unsafe { &*p })
    }
}

/// Claim the process-global meter registry for `queue`. Returns true on
/// success, false if a meter is already active (Perl raises Argument). The
/// compare-and-set makes the claim race-free across concurrently constructed
/// runtimes.
///
/// # Safety
/// `queue` must be a live queue pointer for the registry's lifetime.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_register(
    queue: *mut TemporalioPerlBridgeQueue,
) -> bool {
    if METER_ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return false;
    }
    let registry = Box::new(MeterRegistry {
        queue,
        next_id: std::sync::atomic::AtomicU64::new(0),
        requests: std::sync::Mutex::new(std::collections::VecDeque::new()),
        records: std::sync::Mutex::new(std::collections::HashMap::new()),
    });
    METER_REGISTRY.store(Box::into_raw(registry), Ordering::Release);
    true
}

/// Release the meter registry held by `queue` (no-op unless it is the active
/// one). Called from `Runtime->shutdown` after the worker/runtime that drove
/// the meter is gone, so no callback can still be in flight.
///
/// # Safety
/// Must be called only after core has stopped invoking the meter callbacks.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_unregister(
    queue: *mut TemporalioPerlBridgeQueue,
) {
    let p = METER_REGISTRY.load(Ordering::Acquire);
    if p.is_null() {
        return;
    }
    if (*p).queue != queue {
        return;
    }
    METER_REGISTRY.store(ptr::null_mut(), Ordering::Release);
    drop(Box::from_raw(p));
    METER_ACTIVE.store(false, Ordering::Release);
}

// The eight `TemporalCoreCustomMetricMeter` callbacks. The pointers are exposed
// to Perl via the `*_callback_ptr` accessors below, packed into the meter
// struct Perl hands to `MetricsOptions.custom_meter`.

unsafe fn ref_to_string(r: &TemporalCoreByteArrayRef) -> String {
    if r.data.is_null() || r.size == 0 {
        String::new()
    } else {
        String::from_utf8_lossy(std::slice::from_raw_parts(r.data, r.size)).into_owned()
    }
}

/// `metric_new`: allocate a handle id, park a create request for the main-thread
/// drain (which runs the Perl `create_metric`), and return the id immediately.
/// Never blocks, never calls Perl — safe on any thread including reentrantly on
/// the main thread (spec section 28.2 spike resolution).
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_metric_new(
    name: TemporalCoreByteArrayRef,
    description: TemporalCoreByteArrayRef,
    unit: TemporalCoreByteArrayRef,
    kind: i32,
) -> *const c_void {
    let Some(reg) = meter_registry() else {
        return ptr::null();
    };
    let id = reg.alloc_id();
    reg.park(MeterRequest {
        tag: TEMPORALIO_PERL_BRIDGE_METER_REQ_METRIC_NEW,
        new_id: id,
        name: ref_to_string(&name),
        description: ref_to_string(&description),
        unit: ref_to_string(&unit),
        kind,
        append_from_id: 0,
        attributes: Vec::new(),
        free_id: 0,
    });
    id_to_handle(id)
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_metric_free(metric: *const c_void) {
    let Some(reg) = meter_registry() else { return };
    reg.park(MeterRequest {
        tag: TEMPORALIO_PERL_BRIDGE_METER_REQ_METRIC_FREE,
        new_id: 0,
        name: String::new(),
        description: String::new(),
        unit: String::new(),
        kind: 0,
        append_from_id: 0,
        attributes: Vec::new(),
        free_id: handle_to_id(metric),
    });
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_record_integer(
    metric: *const c_void,
    value: u64,
    attributes: *const c_void,
) {
    let Some(reg) = meter_registry() else { return };
    let metric_id = handle_to_id(metric);
    if metric_id == 0 {
        return; // disabled metric
    }
    reg.record(metric_id, handle_to_id(attributes), 1, value as f64);
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_record_float(
    metric: *const c_void,
    value: f64,
    attributes: *const c_void,
) {
    let Some(reg) = meter_registry() else { return };
    let metric_id = handle_to_id(metric);
    if metric_id == 0 {
        return;
    }
    reg.record(metric_id, handle_to_id(attributes), 2, value);
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_record_duration(
    metric: *const c_void,
    value_ms: u64,
    attributes: *const c_void,
) {
    let Some(reg) = meter_registry() else { return };
    let metric_id = handle_to_id(metric);
    if metric_id == 0 {
        return;
    }
    reg.record(metric_id, handle_to_id(attributes), 3, value_ms as f64);
}

/// `attributes_new`: decode the borrowed attribute array into owned copies,
/// allocate a handle id, park a create request, and return the id immediately
/// (the main-thread drain runs the Perl `new_attributes`). `append_from` is a
/// prior attributes handle (0/null = none). Never blocks, never calls Perl.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_attributes_new(
    append_from: *const c_void,
    attributes: *const TemporalCoreCustomMetricAttribute,
    attributes_size: usize,
) -> *const c_void {
    let Some(reg) = meter_registry() else {
        return ptr::null();
    };
    let mut decoded = Vec::with_capacity(attributes_size);
    if !attributes.is_null() {
        for i in 0..attributes_size {
            let a = &*attributes.add(i);
            let mut attr = MeterAttribute {
                key: ref_to_string(&a.key),
                value_type: a.value_type,
                string_value: String::new(),
                int_value: 0,
                float_value: 0.0,
                bool_value: false,
            };
            match a.value_type {
                1 => {
                    let s = &a.value.string_value;
                    attr.string_value = if s.data.is_null() || s.size == 0 {
                        String::new()
                    } else {
                        String::from_utf8_lossy(std::slice::from_raw_parts(s.data, s.size))
                            .into_owned()
                    };
                }
                2 => attr.int_value = a.value.int_value,
                3 => attr.float_value = a.value.float_value,
                4 => attr.bool_value = a.value.bool_value,
                _ => {}
            }
            decoded.push(attr);
        }
    }
    let id = reg.alloc_id();
    reg.park(MeterRequest {
        tag: TEMPORALIO_PERL_BRIDGE_METER_REQ_ATTRIBUTES_NEW,
        new_id: id,
        name: String::new(),
        description: String::new(),
        unit: String::new(),
        kind: 0,
        append_from_id: handle_to_id(append_from),
        attributes: decoded,
        free_id: 0,
    });
    id_to_handle(id)
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_attributes_free(attributes: *const c_void) {
    let Some(reg) = meter_registry() else { return };
    reg.park(MeterRequest {
        tag: TEMPORALIO_PERL_BRIDGE_METER_REQ_ATTRIBUTES_FREE,
        new_id: 0,
        name: String::new(),
        description: String::new(),
        unit: String::new(),
        kind: 0,
        append_from_id: 0,
        attributes: Vec::new(),
        free_id: handle_to_id(attributes),
    });
}

/// `meter_free`: per the header the custom meter "is freed by a callback within
/// itself". Parked so the Perl meter can release per-meter state on the drain.
/// The `meter` argument is the core meter struct pointer (unused — Perl owns its
/// own meter object via the registry).
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_meter_free(_meter: *const c_void) {
    let Some(reg) = meter_registry() else { return };
    reg.park(MeterRequest {
        tag: TEMPORALIO_PERL_BRIDGE_METER_REQ_METER_FREE,
        new_id: 0,
        name: String::new(),
        description: String::new(),
        unit: String::new(),
        kind: 0,
        append_from_id: 0,
        attributes: Vec::new(),
        free_id: 0,
    });
}

// --- main-thread drain of parked create/free requests -----------------------

/// Pop the next parked create/free request into a heap box and return a raw
/// pointer to it (null if the queue is empty). The Perl drain reads the
/// request's fields via the `req_*` accessors, runs the Perl method, then frees
/// the box with `temporalio_perl_bridge_meter_free_request`. Returns the tag via
/// `*out_tag`.
///
/// # Safety
/// `out_tag` must be a writable `u8` slot.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_next_request(out_tag: *mut u8) -> *const c_void {
    let Some(reg) = meter_registry() else {
        return ptr::null();
    };
    let req = {
        let mut q = reg.requests.lock().unwrap();
        q.pop_front()
    };
    match req {
        None => ptr::null(),
        Some(req) => {
            if !out_tag.is_null() {
                *out_tag = req.tag;
            }
            Box::into_raw(Box::new(req)).cast::<c_void>()
        }
    }
}

/// Free a request box returned by `temporalio_perl_bridge_meter_next_request`
/// once the Perl drain has read its fields.
///
/// # Safety
/// `request` must be a pointer from `meter_next_request`, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_free_request(request: *const c_void) {
    if !request.is_null() {
        drop(Box::from_raw(request.cast::<MeterRequest>().cast_mut()));
    }
}

// Request field accessors (read by the Perl drain).

unsafe fn req_ref<'a>(request: *const c_void) -> &'a MeterRequest {
    &*request.cast::<MeterRequest>()
}

/// The shim-allocated handle id for a create request (metric_new/attributes_new).
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_new_id(request: *const c_void) -> u64 {
    req_ref(request).new_id
}

/// metric_new name (borrowed; valid only while the request is parked).
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_name(
    request: *const c_void,
) -> ForwardedLogByteArrayRef {
    let s = &req_ref(request).name;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_description(
    request: *const c_void,
) -> ForwardedLogByteArrayRef {
    let s = &req_ref(request).description;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_unit(
    request: *const c_void,
) -> ForwardedLogByteArrayRef {
    let s = &req_ref(request).unit;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_kind(request: *const c_void) -> i32 {
    req_ref(request).kind
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_free_id(request: *const c_void) -> u64 {
    req_ref(request).free_id
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_append_from_id(
    request: *const c_void,
) -> u64 {
    req_ref(request).append_from_id
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_attr_count(request: *const c_void) -> usize {
    req_ref(request).attributes.len()
}

/// attribute key at index `i` (borrowed).
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_attr_key(
    request: *const c_void,
    i: usize,
) -> ForwardedLogByteArrayRef {
    let attrs = &req_ref(request).attributes;
    if i >= attrs.len() {
        return ForwardedLogByteArrayRef {
            data: ptr::null(),
            size: 0,
        };
    }
    let s = &attrs[i].key;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

/// attribute value type at index `i` (1=String,2=Int,3=Float,4=Bool), 0 if out
/// of range.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_attr_value_type(
    request: *const c_void,
    i: usize,
) -> i32 {
    let attrs = &req_ref(request).attributes;
    if i >= attrs.len() {
        return 0;
    }
    attrs[i].value_type
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_attr_string(
    request: *const c_void,
    i: usize,
) -> ForwardedLogByteArrayRef {
    let attrs = &req_ref(request).attributes;
    if i >= attrs.len() {
        return ForwardedLogByteArrayRef {
            data: ptr::null(),
            size: 0,
        };
    }
    let s = &attrs[i].string_value;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_attr_int(
    request: *const c_void,
    i: usize,
) -> i64 {
    let attrs = &req_ref(request).attributes;
    if i >= attrs.len() {
        return 0;
    }
    attrs[i].int_value
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_attr_float(
    request: *const c_void,
    i: usize,
) -> f64 {
    let attrs = &req_ref(request).attributes;
    if i >= attrs.len() {
        return 0.0;
    }
    attrs[i].float_value
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_req_attr_bool(
    request: *const c_void,
    i: usize,
) -> bool {
    let attrs = &req_ref(request).attributes;
    if i >= attrs.len() {
        return false;
    }
    attrs[i].bool_value
}

/// Drain the aggregation table into `out_buf` (up to `out_buf_capacity`
/// records), clearing what is drained. Returns the count written. Call in a
/// loop until it returns 0. The Perl meter applies each record to its own
/// counters/histograms/gauges.
///
/// # Safety
/// `out_buf` must point to at least `out_buf_capacity` writable record slots.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_meter_drain_records(
    out_buf: *mut TemporalioPerlBridgeMeterRecord,
    out_buf_capacity: usize,
) -> usize {
    if out_buf.is_null() || out_buf_capacity == 0 {
        return 0;
    }
    let Some(reg) = meter_registry() else {
        return 0;
    };
    let mut table = reg.records.lock().unwrap();
    let mut n = 0;
    let keys: Vec<(u64, u64)> = table.keys().copied().take(out_buf_capacity).collect();
    for key in keys {
        let (record_kind, value, count) = table.remove(&key).unwrap();
        out_buf.add(n).write(TemporalioPerlBridgeMeterRecord {
            metric_id: key.0,
            attributes_id: key.1,
            record_kind,
            value,
            count,
        });
        n += 1;
    }
    n
}

// Pointer accessors for the eight meter callbacks, packed into the
// `TemporalCoreCustomMetricMeter` struct Perl builds for `custom_meter`.

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_metric_new_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_metric_new as *mut c_void
}

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_metric_free_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_metric_free as *mut c_void
}

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_record_integer_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_record_integer as *mut c_void
}

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_record_float_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_record_float as *mut c_void
}

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_record_duration_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_record_duration as *mut c_void
}

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_attributes_new_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_attributes_new as *mut c_void
}

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_attributes_free_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_attributes_free as *mut c_void
}

#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_meter_meter_free_ptr() -> *mut c_void {
    temporalio_perl_bridge_meter_meter_free as *mut c_void
}

// --- Custom slot suppliers (spec section 29.2, the one v0.2 feature needing
// new shim work) -------------------------------------------------------------
//
// Core invokes the six `TemporalCoreCustomSlotSupplierCallbacks` on Tokio
// threads. The same never-touch-Perl-off-core-threads discipline as the metric
// meter applies: the shim NEVER blocks and NEVER calls Perl from a callback. It
// parks a request on the per-runtime queue, signals the wakeup fd, and the
// IO::Async loop drains and runs the Perl method on the main thread.
//
// reserve: async — core hands a `completion_ctx`; the shim parks a reserve
//   request carrying it, and the main-thread drain runs the Perl `reserve_slot`,
//   gets a permit id, and calls `temporal_core_complete_async_reserve`. The
//   `complete` fn pointer is passed in from Perl (FFI::Platypus loads libs
//   RTLD_LOCAL, so the shim cannot reference the undefined core extern directly
//   — the P10.3/P10.4 precedent). The completion pointer is stored as a usize.
// try_reserve: synchronous, returns a permit id or 0. The shim cannot consult
//   Perl synchronously without re-entering a libffi closure, so it always
//   returns 0 (decline). Eager reservations then defer to the async reserve
//   path (T-tuner-6). The request is still parked so Perl can observe the call.
// mark_used / release: non-blocking — park, drain runs the Perl method.
// available_slots / free: see below (available_slots is left NULL; free parks).

/// Request tags the custom-supplier drain switches on (Perl side).
pub const TEMPORALIO_PERL_BRIDGE_SLOT_REQ_RESERVE: u8 = 1;
pub const TEMPORALIO_PERL_BRIDGE_SLOT_REQ_TRY_RESERVE: u8 = 2;
pub const TEMPORALIO_PERL_BRIDGE_SLOT_REQ_MARK_USED: u8 = 3;
pub const TEMPORALIO_PERL_BRIDGE_SLOT_REQ_RELEASE: u8 = 4;
pub const TEMPORALIO_PERL_BRIDGE_SLOT_REQ_FREE: u8 = 5;

/// A `temporal_core_complete_async_reserve` function pointer, stored as a usize
/// so the request struct stays `Send`. Bound once via
/// `temporalio_perl_bridge_supplier_set_complete_reserve`.
static SUPPLIER_COMPLETE_RESERVE: AtomicUsize = AtomicUsize::new(0);

/// The reserve-context fields, copied out of the borrowed `SlotReserveCtx`
/// (valid only for the callback's duration) so the parked request outlives it.
#[derive(Clone, Default)]
struct SlotReserveCtxCopy {
    slot_type: i32,
    task_queue: String,
    worker_identity: String,
    worker_build_id: String,
    is_sticky: bool,
}

/// A parked custom-supplier request the main-thread drain runs.
struct SlotRequest {
    tag: u8,
    /// Which Perl supplier (the user_data id we set in the callbacks struct).
    supplier_id: u64,
    /// Reserve context (reserve / try_reserve).
    ctx: SlotReserveCtxCopy,
    /// Opaque `completion_ctx` pointer for an async reserve, as usize.
    completion_ctx: usize,
    /// Slot kind type for mark_used/release (the slot_info tag), or 0.
    slot_info_type: i32,
    /// Lang-issued permit id for mark_used/release.
    permit: usize,
}

unsafe impl Send for SlotRequest {}

/// One per-runtime custom-supplier registry. Holds the parked requests and the
/// queue to signal. Suppliers are identified by an id (set as the callbacks
/// struct `user_data`); the registry maps ids to nothing Rust-side — the Perl
/// drain owns the Perl supplier objects and dispatches by id.
struct SupplierRegistry {
    queue: *const TemporalioPerlBridgeQueue,
    next_id: AtomicU64,
    requests: std::sync::Mutex<std::collections::VecDeque<SlotRequest>>,
    /// Live callbacks structs leaked for each supplier, reclaimed on unregister.
    callbacks: std::sync::Mutex<Vec<*mut TemporalCoreCustomSlotSupplierCallbacks>>,
}

unsafe impl Send for SupplierRegistry {}
unsafe impl Sync for SupplierRegistry {}

static SUPPLIER_REGISTRY: AtomicPtr<SupplierRegistry> = AtomicPtr::new(ptr::null_mut());
static SUPPLIER_ACTIVE: AtomicBool = AtomicBool::new(false);

impl SupplierRegistry {
    fn alloc_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::AcqRel) + 1
    }

    fn park(&self, req: SlotRequest) {
        {
            let mut q = self.requests.lock().unwrap();
            q.push_back(req);
        }
        if !self.queue.is_null() {
            // SAFETY: queue is a live borrow for the registry's lifetime.
            unsafe { (*self.queue).signal() };
        }
    }
}

fn supplier_registry() -> Option<&'static SupplierRegistry> {
    let p = SUPPLIER_REGISTRY.load(Ordering::Acquire);
    if p.is_null() {
        None
    } else {
        // SAFETY: non-null is a leaked Box live until unregister, which the
        // owning runtime calls only after core has stopped invoking callbacks.
        Some(unsafe { &*p })
    }
}

/// Mirror of `TemporalCoreSlotReserveCtx` (header :598). The borrowed pointer is
/// valid only for the callback's duration; the trampoline copies it out.
#[repr(C)]
pub struct TemporalCoreSlotReserveCtx {
    pub slot_type: i32,
    pub task_queue: TemporalCoreByteArrayRef,
    pub worker_identity: TemporalCoreByteArrayRef,
    pub worker_build_id: TemporalCoreByteArrayRef,
    pub is_sticky: bool,
}

unsafe fn copy_reserve_ctx(ctx: *const TemporalCoreSlotReserveCtx) -> SlotReserveCtxCopy {
    if ctx.is_null() {
        return SlotReserveCtxCopy::default();
    }
    let c = &*ctx;
    SlotReserveCtxCopy {
        slot_type: c.slot_type,
        task_queue: ref_to_string(&c.task_queue),
        worker_identity: ref_to_string(&c.worker_identity),
        worker_build_id: ref_to_string(&c.worker_build_id),
        is_sticky: c.is_sticky,
    }
}

/// The six custom-supplier callbacks core invokes. The signatures match the
/// header typedefs; `user_data` is the supplier id we set when building the
/// callbacks struct.

/// reserve: park a reserve request carrying the completion ctx, return. The
/// drain runs the Perl `reserve_slot` and completes the async reservation.
unsafe extern "C" fn supplier_reserve(
    ctx: *const TemporalCoreSlotReserveCtx,
    completion_ctx: *const c_void,
    user_data: *mut c_void,
) {
    let Some(reg) = supplier_registry() else { return };
    reg.park(SlotRequest {
        tag: TEMPORALIO_PERL_BRIDGE_SLOT_REQ_RESERVE,
        supplier_id: user_data as u64,
        ctx: copy_reserve_ctx(ctx),
        completion_ctx: completion_ctx as usize,
        slot_info_type: 0,
        permit: 0,
    });
}

/// cancel_reserve: core cancels a pending reserve. The shim parks nothing and
/// relies on the main-thread drain having already (or about to) complete the
/// reservation; cancellation completion is a no-op here because the Perl
/// reserve_slot resolves immediately on drain (best-effort, spec §29.2).
unsafe extern "C" fn supplier_cancel_reserve(
    _completion_ctx: *const c_void,
    _user_data: *mut c_void,
) {
}

/// try_reserve: synchronous eager path. The shim cannot consult Perl
/// synchronously, so it parks the call (for observability) and declines (0).
/// Eager reservations defer to the async reserve path (T-tuner-6).
unsafe extern "C" fn supplier_try_reserve(
    ctx: *const TemporalCoreSlotReserveCtx,
    user_data: *mut c_void,
) -> usize {
    let Some(reg) = supplier_registry() else { return 0 };
    reg.park(SlotRequest {
        tag: TEMPORALIO_PERL_BRIDGE_SLOT_REQ_TRY_RESERVE,
        supplier_id: user_data as u64,
        ctx: copy_reserve_ctx(ctx),
        completion_ctx: 0,
        slot_info_type: 0,
        permit: 0,
    });
    0
}

/// Mirror of `TemporalCoreSlotMarkUsedCtx` enough to read the permit and the
/// slot_info tag (the first u32 of the SlotInfo union).
#[repr(C)]
pub struct TemporalCoreSlotMarkUsedCtxHeader {
    pub slot_info_tag: i32,
}

unsafe extern "C" fn supplier_mark_used(ctx: *const c_void, user_data: *mut c_void) {
    let Some(reg) = supplier_registry() else { return };
    // SlotMarkUsedCtx { SlotInfo slot_info; uintptr_t slot_permit; }. SlotInfo
    // is { u32 tag; <union> }; the union is at most two ByteArrayRefs (32 bytes)
    // plus the tag word (8 with padding) = 40 bytes, so slot_permit is at
    // offset 40. Read the tag at 0 and the permit at 40.
    let (tag, permit) = if ctx.is_null() {
        (0, 0)
    } else {
        let base = ctx as *const u8;
        let tag = *(base as *const i32);
        let permit = *(base.add(40) as *const usize);
        (tag, permit)
    };
    reg.park(SlotRequest {
        tag: TEMPORALIO_PERL_BRIDGE_SLOT_REQ_MARK_USED,
        supplier_id: user_data as u64,
        ctx: SlotReserveCtxCopy::default(),
        completion_ctx: 0,
        slot_info_type: tag,
        permit,
    });
}

unsafe extern "C" fn supplier_release(ctx: *const c_void, user_data: *mut c_void) {
    let Some(reg) = supplier_registry() else { return };
    // SlotReleaseCtx { const SlotInfo *slot_info; uintptr_t slot_permit; }.
    // slot_info may be null (slot never used); slot_permit is at offset 8.
    let (tag, permit) = if ctx.is_null() {
        (0, 0)
    } else {
        let base = ctx as *const u8;
        let info_ptr = *(base as *const usize) as *const i32;
        let tag = if info_ptr.is_null() { -1 } else { *info_ptr };
        let permit = *(base.add(8) as *const usize);
        (tag, permit)
    };
    reg.park(SlotRequest {
        tag: TEMPORALIO_PERL_BRIDGE_SLOT_REQ_RELEASE,
        supplier_id: user_data as u64,
        ctx: SlotReserveCtxCopy::default(),
        completion_ctx: 0,
        slot_info_type: tag,
        permit,
    });
}

/// free: core drops the supplier. Park a free request so Perl can release its
/// per-supplier state; the callbacks struct itself is reclaimed at unregister.
unsafe extern "C" fn supplier_free(userimpl: *const c_void) {
    let Some(reg) = supplier_registry() else { return };
    // userimpl is &CustomSlotSupplierCallbacksImpl ( == &(&callbacks) ); recover
    // the supplier id from the callbacks struct's user_data.
    let supplier_id = if userimpl.is_null() {
        0
    } else {
        let cb_ptr = *(userimpl as *const usize) as *const TemporalCoreCustomSlotSupplierCallbacks;
        if cb_ptr.is_null() {
            0
        } else {
            (*cb_ptr).user_data as u64
        }
    };
    reg.park(SlotRequest {
        tag: TEMPORALIO_PERL_BRIDGE_SLOT_REQ_FREE,
        supplier_id,
        ctx: SlotReserveCtxCopy::default(),
        completion_ctx: 0,
        slot_info_type: 0,
        permit: 0,
    });
}

/// The `TemporalCoreCustomSlotSupplierCallbacks` struct core retains by pointer.
/// Mirrors the header field-for-field. `user_data` is the supplier id; the
/// other fields are our callback function pointers.
#[repr(C)]
pub struct TemporalCoreCustomSlotSupplierCallbacks {
    pub reserve: unsafe extern "C" fn(
        *const TemporalCoreSlotReserveCtx,
        *const c_void,
        *mut c_void,
    ),
    pub cancel_reserve: unsafe extern "C" fn(*const c_void, *mut c_void),
    pub try_reserve:
        unsafe extern "C" fn(*const TemporalCoreSlotReserveCtx, *mut c_void) -> usize,
    pub mark_used: unsafe extern "C" fn(*const c_void, *mut c_void),
    pub release: unsafe extern "C" fn(*const c_void, *mut c_void),
    /// available_slots — left NULL (core treats it as "never known").
    pub available_slots: usize,
    pub free: unsafe extern "C" fn(*const c_void),
    pub user_data: *mut c_void,
}

/// Claim the process-global supplier registry for `queue`. Returns true on
/// success, false if one is already active (Perl raises Argument).
///
/// # Safety
/// `queue` must be a live queue pointer for the registry's lifetime.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_supplier_register(
    queue: *mut TemporalioPerlBridgeQueue,
) -> bool {
    if SUPPLIER_ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        // Already active: succeed if it is the SAME queue (multiple workers on
        // one runtime share the registry — their suppliers accumulate), fail
        // only for a different runtime's queue (the one-per-process rule).
        let p = SUPPLIER_REGISTRY.load(Ordering::Acquire);
        return !p.is_null() && (*p).queue == queue;
    }
    let registry = Box::new(SupplierRegistry {
        queue,
        next_id: AtomicU64::new(0),
        requests: std::sync::Mutex::new(std::collections::VecDeque::new()),
        callbacks: std::sync::Mutex::new(Vec::new()),
    });
    SUPPLIER_REGISTRY.store(Box::into_raw(registry), Ordering::Release);
    true
}

/// Release the supplier registry held by `queue`, freeing every leaked
/// callbacks struct. Called from `Runtime->shutdown` after the worker is gone.
///
/// # Safety
/// Must be called only after core has stopped invoking the supplier callbacks.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_supplier_unregister(
    queue: *mut TemporalioPerlBridgeQueue,
) {
    let p = SUPPLIER_REGISTRY.load(Ordering::Acquire);
    if p.is_null() || (*p).queue != queue {
        return;
    }
    SUPPLIER_REGISTRY.store(ptr::null_mut(), Ordering::Release);
    let reg = Box::from_raw(p);
    {
        let mut cbs = reg.callbacks.lock().unwrap();
        for cb in cbs.drain(..) {
            drop(Box::from_raw(cb));
        }
    }
    drop(reg);
    SUPPLIER_ACTIVE.store(false, Ordering::Release);
}

/// Bind the `temporal_core_complete_async_reserve` fn pointer (passed in from
/// Perl via find_symbol, since the shim cannot reference the core extern under
/// RTLD_LOCAL — the P10.3 precedent).
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_supplier_set_complete_reserve(ptr: *mut c_void) {
    SUPPLIER_COMPLETE_RESERVE.store(ptr as usize, Ordering::Release);
}

/// Build a custom-supplier callbacks struct, leak it, and return its pointer
/// (the value packed into the Custom slot-supplier union). Allocates a supplier
/// id stored as `user_data`. Returns null if no registry is active.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_supplier_new() -> *const c_void {
    let Some(reg) = supplier_registry() else {
        return ptr::null();
    };
    let id = reg.alloc_id();
    let callbacks = Box::new(TemporalCoreCustomSlotSupplierCallbacks {
        reserve: supplier_reserve,
        cancel_reserve: supplier_cancel_reserve,
        try_reserve: supplier_try_reserve,
        mark_used: supplier_mark_used,
        release: supplier_release,
        available_slots: 0,
        free: supplier_free,
        user_data: id as *mut c_void,
    });
    let raw = Box::into_raw(callbacks);
    {
        let mut cbs = reg.callbacks.lock().unwrap();
        cbs.push(raw);
    }
    raw as *const c_void
}

/// Read the supplier id (the callbacks struct `user_data`) from a callbacks
/// pointer returned by `supplier_new`. Perl uses it to bind the registry's
/// impl dispatch.
///
/// # Safety
/// `callbacks` must be a pointer from `supplier_new`, still live.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_supplier_callbacks_user_data(
    callbacks: *const c_void,
) -> u64 {
    if callbacks.is_null() {
        return 0;
    }
    (*(callbacks as *const TemporalCoreCustomSlotSupplierCallbacks)).user_data as u64
}

/// Pop the next parked supplier request into a heap box; return its pointer
/// (null when empty) and write the tag via `out_tag`. The Perl drain reads the
/// request via the `slot_req_*` accessors, runs the Perl method, then frees it
/// with `temporalio_perl_bridge_supplier_free_request`.
///
/// # Safety
/// `out_tag` must be a writable u8 slot.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_supplier_next_request(
    out_tag: *mut u8,
) -> *const c_void {
    let Some(reg) = supplier_registry() else {
        return ptr::null();
    };
    let req = {
        let mut q = reg.requests.lock().unwrap();
        q.pop_front()
    };
    match req {
        None => ptr::null(),
        Some(req) => {
            if !out_tag.is_null() {
                *out_tag = req.tag;
            }
            Box::into_raw(Box::new(req)).cast::<c_void>()
        }
    }
}

/// Free a request box returned by `supplier_next_request`.
///
/// # Safety
/// `request` must be a pointer from `supplier_next_request`, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_supplier_free_request(request: *const c_void) {
    if !request.is_null() {
        drop(Box::from_raw(request.cast::<SlotRequest>().cast_mut()));
    }
}

unsafe fn slot_req<'a>(request: *const c_void) -> &'a SlotRequest {
    &*request.cast::<SlotRequest>()
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_supplier_id(request: *const c_void) -> u64 {
    slot_req(request).supplier_id
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_slot_type(request: *const c_void) -> i32 {
    slot_req(request).ctx.slot_type
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_is_sticky(request: *const c_void) -> bool {
    slot_req(request).ctx.is_sticky
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_task_queue(
    request: *const c_void,
) -> ForwardedLogByteArrayRef {
    let s = &slot_req(request).ctx.task_queue;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_worker_identity(
    request: *const c_void,
) -> ForwardedLogByteArrayRef {
    let s = &slot_req(request).ctx.worker_identity;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_worker_build_id(
    request: *const c_void,
) -> ForwardedLogByteArrayRef {
    let s = &slot_req(request).ctx.worker_build_id;
    ForwardedLogByteArrayRef {
        data: s.as_ptr(),
        size: s.len(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_completion_ctx(
    request: *const c_void,
) -> *const c_void {
    slot_req(request).completion_ctx as *const c_void
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_permit(request: *const c_void) -> usize {
    slot_req(request).permit
}

#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_slot_req_slot_info_type(
    request: *const c_void,
) -> i32 {
    slot_req(request).slot_info_type
}

/// Complete an async reservation: call the bound
/// `temporal_core_complete_async_reserve(completion_ctx, permit_id)`. Returns
/// true if it completed (false means core cancelled before completion — the
/// caller should drop the permit). No-op (false) if no completion fn is bound.
///
/// # Safety
/// `completion_ctx` must be a pointer from a parked reserve request, used once.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_supplier_complete_reserve(
    completion_ctx: *const c_void,
    permit_id: usize,
) -> bool {
    let f = SUPPLIER_COMPLETE_RESERVE.load(Ordering::Acquire);
    if f == 0 || completion_ctx.is_null() {
        return false;
    }
    let complete: unsafe extern "C" fn(*const c_void, usize) -> bool =
        std::mem::transmute(f);
    complete(completion_ctx, permit_id)
}

// The custom-metric attribute types core passes to `attributes_new`. Mirrors
// `TemporalCoreCustomMetricAttribute*` from temporal-sdk-core-c-bridge.h (the
// shim parses them; cbindgen excludes them so the header carries no conflicting
// definition).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct TemporalCoreCustomMetricAttributeValueString {
    pub data: *const u8,
    pub size: usize,
}

#[repr(C)]
pub union TemporalCoreCustomMetricAttributeValue {
    pub string_value: TemporalCoreCustomMetricAttributeValueString,
    pub int_value: i64,
    pub float_value: f64,
    pub bool_value: bool,
}

#[repr(C)]
pub struct TemporalCoreCustomMetricAttribute {
    pub key: TemporalCoreByteArrayRef,
    pub value: TemporalCoreCustomMetricAttributeValue,
    pub value_type: i32,
}

/// Allocate a queue signalling `signal_fd` (eventfd, or pipe write-end as
/// the portable fallback — detected via fstat). The fd must be non-blocking;
/// the queue borrows it and never closes it.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_queue_new(
    signal_fd: i32,
) -> *mut TemporalioPerlBridgeQueue {
    Box::into_raw(Box::new(TemporalioPerlBridgeQueue {
        entries: SegQueue::new(),
        signal_fd: AtomicI32::new(signal_fd),
        signal_is_fifo: fd_is_fifo(signal_fd),
    }))
}

/// Free the queue, dropping any undrained entries. The caller must guarantee
/// no further pushes (no pending async calls hold a pair into this queue).
///
/// # Safety
/// `q` must be a pointer returned by `temporalio_perl_bridge_queue_new` that
/// has not already been freed.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_queue_free(q: *mut TemporalioPerlBridgeQueue) {
    if !q.is_null() {
        drop(Box::from_raw(q));
    }
}

/// Pair `q` with a Perl-side callback id. The returned pointer is the
/// `user_data` argument for sdk-core-c-bridge async calls. Single-shot: the
/// trampoline frees it after enqueueing the completion entry. This is how
/// multiple runtimes each route completions to their own queue.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_user_data_new(
    q: *mut TemporalioPerlBridgeQueue,
    callback_id: u64,
) -> *mut c_void {
    Box::into_raw(Box::new(UserData {
        queue: q,
        callback_id,
    }))
    .cast::<c_void>()
}

/// Non-blocking drain, called from the Perl main thread when the signal fd
/// reads ready. Clears the eventfd, then pops up to `out_buf_capacity`
/// entries into `out_buf` and returns the count. Call in a loop until it
/// returns 0. ByteArray pointers in the entries must be freed by the caller.
///
/// # Safety
/// `q` must be a live queue pointer and `out_buf` must point to at least
/// `out_buf_capacity` writable `TemporalioPerlBridgeEntry` slots.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_queue_drain(
    q: *mut TemporalioPerlBridgeQueue,
    out_buf: *mut TemporalioPerlBridgeEntry,
    out_buf_capacity: usize,
) -> usize {
    if q.is_null() || out_buf.is_null() || out_buf_capacity == 0 {
        return 0;
    }
    let queue = &*q;
    queue.clear_signal();
    let mut n = 0;
    while n < out_buf_capacity {
        match queue.entries.pop() {
            Some(entry) => {
                out_buf.add(n).write(entry);
                n += 1;
            }
            None => break,
        }
    }
    n
}

/// Trampoline for `TemporalCoreWorkerPollCallback` (kind 1).
///
/// # Safety
/// `user_data` must be a pointer from `temporalio_perl_bridge_user_data_new`
/// not yet consumed by any trampoline.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_worker_poll_callback(
    user_data: *mut c_void,
    success: *const TemporalCoreByteArray,
    fail: *const TemporalCoreByteArray,
) {
    complete(user_data, |callback_id| TemporalioPerlBridgeEntry {
        callback_id,
        kind: TEMPORALIO_PERL_BRIDGE_KIND_WORKER_POLL,
        success_ba: success,
        fail_ba: fail,
        ..TemporalioPerlBridgeEntry::empty()
    });
}

/// Trampoline for `TemporalCoreWorkerCallback` (kind 2).
///
/// # Safety
/// See `temporalio_perl_bridge_worker_poll_callback`.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_worker_callback(
    user_data: *mut c_void,
    fail: *const TemporalCoreByteArray,
) {
    complete(user_data, |callback_id| TemporalioPerlBridgeEntry {
        callback_id,
        kind: TEMPORALIO_PERL_BRIDGE_KIND_WORKER,
        fail_ba: fail,
        ..TemporalioPerlBridgeEntry::empty()
    });
}

/// Trampoline for `TemporalCoreClientConnectCallback` (kind 3).
///
/// # Safety
/// See `temporalio_perl_bridge_worker_poll_callback`.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_client_connect_callback(
    user_data: *mut c_void,
    success: *mut TemporalCoreConnection,
    fail: *const TemporalCoreByteArray,
) {
    complete(user_data, |callback_id| TemporalioPerlBridgeEntry {
        callback_id,
        kind: TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_CONNECT,
        success_handle: success.cast::<c_void>(),
        fail_ba: fail,
        ..TemporalioPerlBridgeEntry::empty()
    });
}

/// Trampoline for `TemporalCoreClientRpcCallCallback` (kind 4). The
/// `failure_message` rides in `fail_ba`.
///
/// # Safety
/// See `temporalio_perl_bridge_worker_poll_callback`.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_client_rpc_call_callback(
    user_data: *mut c_void,
    success: *const TemporalCoreByteArray,
    status_code: u32,
    failure_message: *const TemporalCoreByteArray,
    failure_details: *const TemporalCoreByteArray,
) {
    complete(user_data, |callback_id| TemporalioPerlBridgeEntry {
        callback_id,
        kind: TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_RPC_CALL,
        success_ba: success,
        fail_ba: failure_message,
        rpc_status_code: status_code,
        rpc_failure_details: failure_details,
        ..TemporalioPerlBridgeEntry::empty()
    });
}

/// Trampoline for `TemporalCoreEphemeralServerStartCallback` (kind 5).
///
/// # Safety
/// See `temporalio_perl_bridge_worker_poll_callback`.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_ephemeral_server_start_callback(
    user_data: *mut c_void,
    success: *mut TemporalCoreEphemeralServer,
    success_target: *const TemporalCoreByteArray,
    fail: *const TemporalCoreByteArray,
) {
    complete(user_data, |callback_id| TemporalioPerlBridgeEntry {
        callback_id,
        kind: TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_START,
        success_handle: success.cast::<c_void>(),
        ephemeral_target: success_target,
        fail_ba: fail,
        ..TemporalioPerlBridgeEntry::empty()
    });
}

/// Trampoline for `TemporalCoreEphemeralServerShutdownCallback` (kind 6).
///
/// # Safety
/// See `temporalio_perl_bridge_worker_poll_callback`.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_ephemeral_server_shutdown_callback(
    user_data: *mut c_void,
    fail: *const TemporalCoreByteArray,
) {
    complete(user_data, |callback_id| TemporalioPerlBridgeEntry {
        callback_id,
        kind: TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_SHUTDOWN,
        fail_ba: fail,
        ..TemporalioPerlBridgeEntry::empty()
    });
}

/// Address of the worker-poll trampoline, for passing as the callback
/// argument to sdk-core-c-bridge functions.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_worker_poll_callback_ptr() -> *mut c_void {
    temporalio_perl_bridge_worker_poll_callback as *mut c_void
}

/// Address of the worker trampoline.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_worker_callback_ptr() -> *mut c_void {
    temporalio_perl_bridge_worker_callback as *mut c_void
}

/// Address of the client-connect trampoline.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_client_connect_callback_ptr() -> *mut c_void {
    temporalio_perl_bridge_client_connect_callback as *mut c_void
}

/// Address of the client-rpc-call trampoline.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_client_rpc_call_callback_ptr() -> *mut c_void {
    temporalio_perl_bridge_client_rpc_call_callback as *mut c_void
}

/// Address of the ephemeral-server-start trampoline.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_ephemeral_server_start_callback_ptr() -> *mut c_void {
    temporalio_perl_bridge_ephemeral_server_start_callback as *mut c_void
}

/// Address of the ephemeral-server-shutdown trampoline.
#[no_mangle]
pub extern "C" fn temporalio_perl_bridge_ephemeral_server_shutdown_callback_ptr() -> *mut c_void {
    temporalio_perl_bridge_ephemeral_server_shutdown_callback as *mut c_void
}

// --- WorkerOptions echo (plan P0.10, spec section 11 risk spike 3) ----------
//
// Layout mirrors of the `TemporalCoreWorkerOptions` tree, transcribed from
// temporal-sdk-core-c-bridge's own #[repr(C)] definitions (worker.rs) at the
// pinned sdk-rust tag — identical repr(C) Rust source guarantees identical
// layout. The debug echo function parses a struct built by the Perl side and
// returns a printable field-for-field summary, so the Perl marshalling test
// can verify every offset without a server or a live worker. cbindgen
// excludes these types from the generated header (they belong to
// temporal-sdk-core-c-bridge.h); only a forward typedef of
// TemporalCoreWorkerOptions is emitted for the function signature.

#[repr(C)]
pub struct TemporalCoreByteArrayRef {
    pub data: *const u8,
    pub size: usize,
}

#[repr(C)]
pub struct TemporalCoreByteArrayRefArray {
    pub data: *const TemporalCoreByteArrayRef,
    pub size: usize,
}

#[repr(C)]
pub struct TemporalCoreWorkerVersioningNone {
    pub build_id: TemporalCoreByteArrayRef,
}

#[repr(C)]
pub struct TemporalCoreWorkerDeploymentVersion {
    pub deployment_name: TemporalCoreByteArrayRef,
    pub build_id: TemporalCoreByteArrayRef,
}

#[repr(C)]
pub struct TemporalCoreWorkerDeploymentOptions {
    pub version: TemporalCoreWorkerDeploymentVersion,
    pub use_worker_versioning: bool,
    pub default_versioning_behavior: i32,
}

#[repr(C)]
pub struct TemporalCoreLegacyBuildIdBasedStrategy {
    pub build_id: TemporalCoreByteArrayRef,
}

#[repr(C)]
pub enum TemporalCoreWorkerVersioningStrategy {
    None(TemporalCoreWorkerVersioningNone),
    DeploymentBased(TemporalCoreWorkerDeploymentOptions),
    LegacyBuildIdBased(TemporalCoreLegacyBuildIdBasedStrategy),
}

#[repr(C)]
pub struct TemporalCoreFixedSizeSlotSupplier {
    pub num_slots: usize,
}

#[repr(C)]
pub struct TemporalCoreResourceBasedTunerOptions {
    pub target_memory_usage: f64,
    pub target_cpu_usage: f64,
}

#[repr(C)]
pub struct TemporalCoreResourceBasedSlotSupplier {
    pub minimum_slots: usize,
    pub maximum_slots: usize,
    pub ramp_throttle_ms: u64,
    pub tuner_options: TemporalCoreResourceBasedTunerOptions,
}

/// Borrowed custom-supplier callback table: a single pointer the shim never
/// dereferences (custom suppliers are Phase 6+; the bridge's struct member is
/// `*const TemporalCoreCustomSlotSupplierCallbacks` — layout-identical).
#[repr(C)]
pub struct TemporalCoreCustomSlotSupplierCallbacksImpl(pub *const c_void);

#[repr(C)]
pub enum TemporalCoreSlotSupplier {
    FixedSize(TemporalCoreFixedSizeSlotSupplier),
    ResourceBased(TemporalCoreResourceBasedSlotSupplier),
    Custom(TemporalCoreCustomSlotSupplierCallbacksImpl),
}

#[repr(C)]
pub struct TemporalCoreTunerHolder {
    pub workflow_slot_supplier: TemporalCoreSlotSupplier,
    pub activity_slot_supplier: TemporalCoreSlotSupplier,
    pub local_activity_slot_supplier: TemporalCoreSlotSupplier,
    pub nexus_task_slot_supplier: TemporalCoreSlotSupplier,
}

#[repr(C)]
pub struct TemporalCoreWorkerTaskTypes {
    pub enable_workflows: bool,
    pub enable_local_activities: bool,
    pub enable_remote_activities: bool,
    pub enable_nexus: bool,
}

#[repr(C)]
pub struct TemporalCorePollerBehaviorSimpleMaximum {
    pub simple_maximum: usize,
}

#[repr(C)]
pub struct TemporalCorePollerBehaviorAutoscaling {
    pub minimum: usize,
    pub maximum: usize,
    pub initial: usize,
}

#[repr(C)]
pub struct TemporalCorePollerBehavior {
    pub simple_maximum: *const TemporalCorePollerBehaviorSimpleMaximum,
    pub autoscaling: *const TemporalCorePollerBehaviorAutoscaling,
}

#[repr(C)]
pub struct TemporalCoreWorkerOptions {
    pub namespace: TemporalCoreByteArrayRef,
    pub task_queue: TemporalCoreByteArrayRef,
    pub versioning_strategy: TemporalCoreWorkerVersioningStrategy,
    pub identity_override: TemporalCoreByteArrayRef,
    pub max_cached_workflows: u32,
    pub tuner: TemporalCoreTunerHolder,
    pub task_types: TemporalCoreWorkerTaskTypes,
    pub sticky_queue_schedule_to_start_timeout_millis: u64,
    pub max_heartbeat_throttle_interval_millis: u64,
    pub default_heartbeat_throttle_interval_millis: u64,
    pub max_activities_per_second: f64,
    pub max_task_queue_activities_per_second: f64,
    pub graceful_shutdown_period_millis: u64,
    pub workflow_task_poller_behavior: TemporalCorePollerBehavior,
    pub nonsticky_to_sticky_poll_ratio: f32,
    pub activity_task_poller_behavior: TemporalCorePollerBehavior,
    pub nexus_task_poller_behavior: TemporalCorePollerBehavior,
    pub nondeterminism_as_workflow_fail: bool,
    pub nondeterminism_as_workflow_fail_for_types: TemporalCoreByteArrayRefArray,
    pub plugins: TemporalCoreByteArrayRefArray,
    pub storage_drivers: TemporalCoreByteArrayRefArray,
}

/// String form of a borrowed byte-array ref: `<null>` for a null data
/// pointer, else the bytes decoded lossily as UTF-8.
unsafe fn fmt_byte_array_ref(r: &TemporalCoreByteArrayRef) -> String {
    if r.data.is_null() {
        "<null>".to_owned()
    } else {
        String::from_utf8_lossy(std::slice::from_raw_parts(r.data, r.size)).into_owned()
    }
}

/// `[a,b,...]` form of a ref array; `[]` for null/empty.
unsafe fn fmt_byte_array_ref_array(a: &TemporalCoreByteArrayRefArray) -> String {
    if a.data.is_null() || a.size == 0 {
        return "[]".to_owned();
    }
    let items: Vec<String> = std::slice::from_raw_parts(a.data, a.size)
        .iter()
        .map(|r| fmt_byte_array_ref(r))
        .collect();
    format!("[{}]", items.join(","))
}

unsafe fn fmt_slot_supplier(s: &TemporalCoreSlotSupplier) -> String {
    match s {
        TemporalCoreSlotSupplier::FixedSize(f) => format!("FixedSize({})", f.num_slots),
        TemporalCoreSlotSupplier::ResourceBased(r) => format!(
            "ResourceBased(min={},max={},ramp_ms={},mem={},cpu={})",
            r.minimum_slots,
            r.maximum_slots,
            r.ramp_throttle_ms,
            r.tuner_options.target_memory_usage,
            r.tuner_options.target_cpu_usage,
        ),
        TemporalCoreSlotSupplier::Custom(_) => "Custom".to_owned(),
    }
}

unsafe fn fmt_poller_behavior(p: &TemporalCorePollerBehavior) -> String {
    match (p.simple_maximum.as_ref(), p.autoscaling.as_ref()) {
        (Some(s), None) => format!("simple_maximum({})", s.simple_maximum),
        (None, Some(a)) => format!(
            "autoscaling(min={},max={},initial={})",
            a.minimum, a.maximum, a.initial
        ),
        (None, None) => "<none>".to_owned(),
        (Some(_), Some(_)) => "<both>".to_owned(),
    }
}

/// Parse a `TemporalCoreWorkerOptions` built by the caller and return a
/// newline-delimited `field=value` summary covering every field in struct
/// order, as a NUL-terminated string. Free the result with
/// [`temporalio_perl_bridge_string_free`]. Debug-only: this exists so the
/// Perl SDK's marshalling can be verified empirically (plan P0.10) without a
/// server connection.
///
/// # Safety
/// `options` must be null or point to a fully initialized
/// `TemporalCoreWorkerOptions` whose pointers remain valid for the call.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_debug_worker_options(
    options: *const TemporalCoreWorkerOptions,
) -> *mut c_char {
    use std::fmt::Write as _;

    let mut out = String::new();
    match options.as_ref() {
        None => out.push_str("options=<null>\n"),
        Some(o) => {
            let _ = writeln!(out, "namespace={}", fmt_byte_array_ref(&o.namespace));
            let _ = writeln!(out, "task_queue={}", fmt_byte_array_ref(&o.task_queue));
            match &o.versioning_strategy {
                TemporalCoreWorkerVersioningStrategy::None(n) => {
                    out.push_str("versioning_strategy.tag=None\n");
                    let _ = writeln!(
                        out,
                        "versioning_strategy.none.build_id={}",
                        fmt_byte_array_ref(&n.build_id)
                    );
                }
                TemporalCoreWorkerVersioningStrategy::DeploymentBased(d) => {
                    out.push_str("versioning_strategy.tag=DeploymentBased\n");
                    let _ = writeln!(
                        out,
                        "versioning_strategy.deployment.deployment_name={}",
                        fmt_byte_array_ref(&d.version.deployment_name)
                    );
                    let _ = writeln!(
                        out,
                        "versioning_strategy.deployment.build_id={}",
                        fmt_byte_array_ref(&d.version.build_id)
                    );
                    let _ = writeln!(
                        out,
                        "versioning_strategy.deployment.use_worker_versioning={}",
                        d.use_worker_versioning
                    );
                    let _ = writeln!(
                        out,
                        "versioning_strategy.deployment.default_versioning_behavior={}",
                        d.default_versioning_behavior
                    );
                }
                TemporalCoreWorkerVersioningStrategy::LegacyBuildIdBased(l) => {
                    out.push_str("versioning_strategy.tag=LegacyBuildIdBased\n");
                    let _ = writeln!(
                        out,
                        "versioning_strategy.legacy.build_id={}",
                        fmt_byte_array_ref(&l.build_id)
                    );
                }
            }
            let _ = writeln!(
                out,
                "identity_override={}",
                fmt_byte_array_ref(&o.identity_override)
            );
            let _ = writeln!(out, "max_cached_workflows={}", o.max_cached_workflows);
            for (name, supplier) in [
                ("workflow_slot_supplier", &o.tuner.workflow_slot_supplier),
                ("activity_slot_supplier", &o.tuner.activity_slot_supplier),
                (
                    "local_activity_slot_supplier",
                    &o.tuner.local_activity_slot_supplier,
                ),
                (
                    "nexus_task_slot_supplier",
                    &o.tuner.nexus_task_slot_supplier,
                ),
            ] {
                let _ = writeln!(out, "tuner.{name}={}", fmt_slot_supplier(supplier));
            }
            let _ = writeln!(
                out,
                "task_types.enable_workflows={}",
                o.task_types.enable_workflows
            );
            let _ = writeln!(
                out,
                "task_types.enable_local_activities={}",
                o.task_types.enable_local_activities
            );
            let _ = writeln!(
                out,
                "task_types.enable_remote_activities={}",
                o.task_types.enable_remote_activities
            );
            let _ = writeln!(out, "task_types.enable_nexus={}", o.task_types.enable_nexus);
            let _ = writeln!(
                out,
                "sticky_queue_schedule_to_start_timeout_millis={}",
                o.sticky_queue_schedule_to_start_timeout_millis
            );
            let _ = writeln!(
                out,
                "max_heartbeat_throttle_interval_millis={}",
                o.max_heartbeat_throttle_interval_millis
            );
            let _ = writeln!(
                out,
                "default_heartbeat_throttle_interval_millis={}",
                o.default_heartbeat_throttle_interval_millis
            );
            let _ = writeln!(
                out,
                "max_activities_per_second={}",
                o.max_activities_per_second
            );
            let _ = writeln!(
                out,
                "max_task_queue_activities_per_second={}",
                o.max_task_queue_activities_per_second
            );
            let _ = writeln!(
                out,
                "graceful_shutdown_period_millis={}",
                o.graceful_shutdown_period_millis
            );
            let _ = writeln!(
                out,
                "workflow_task_poller_behavior={}",
                fmt_poller_behavior(&o.workflow_task_poller_behavior)
            );
            let _ = writeln!(
                out,
                "nonsticky_to_sticky_poll_ratio={}",
                o.nonsticky_to_sticky_poll_ratio
            );
            let _ = writeln!(
                out,
                "activity_task_poller_behavior={}",
                fmt_poller_behavior(&o.activity_task_poller_behavior)
            );
            let _ = writeln!(
                out,
                "nexus_task_poller_behavior={}",
                fmt_poller_behavior(&o.nexus_task_poller_behavior)
            );
            let _ = writeln!(
                out,
                "nondeterminism_as_workflow_fail={}",
                o.nondeterminism_as_workflow_fail
            );
            let _ = writeln!(
                out,
                "nondeterminism_as_workflow_fail_for_types={}",
                fmt_byte_array_ref_array(&o.nondeterminism_as_workflow_fail_for_types)
            );
            let _ = writeln!(out, "plugins={}", fmt_byte_array_ref_array(&o.plugins));
            let _ = writeln!(
                out,
                "storage_drivers={}",
                fmt_byte_array_ref_array(&o.storage_drivers)
            );
        }
    }
    match std::ffi::CString::new(out) {
        Ok(s) => s.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Free a string returned by [`temporalio_perl_bridge_debug_worker_options`].
///
/// # Safety
/// `s` must be null or a pointer previously returned by this crate's
/// string-returning functions, not yet freed.
#[no_mangle]
pub unsafe extern "C" fn temporalio_perl_bridge_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(std::ffi::CString::from_raw(s));
    }
}

// T-shim-1..4 plus user_data routing, trampoline field shapes, pointer
// accessors, and the generated-header contract. Spec section 3.
#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use std::ffi::c_void;
    use std::ptr;

    fn nonblocking_pipe() -> (i32, i32) {
        let mut fds = [0i32; 2];
        assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0, "pipe() failed");
        for fd in fds {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            assert!(flags >= 0);
            assert!(unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } >= 0);
        }
        (fds[0], fds[1])
    }

    #[cfg(target_os = "linux")]
    fn nonblocking_eventfd() -> i32 {
        let fd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        assert!(fd >= 0, "eventfd() failed");
        fd
    }

    fn zeroed_entries(n: usize) -> Vec<TemporalioPerlBridgeEntry> {
        (0..n).map(|_| TemporalioPerlBridgeEntry::empty()).collect()
    }

    unsafe fn drain_chunk(
        q: *mut TemporalioPerlBridgeQueue,
        cap: usize,
    ) -> Vec<TemporalioPerlBridgeEntry> {
        let mut buf = zeroed_entries(cap);
        let n = temporalio_perl_bridge_queue_drain(q, buf.as_mut_ptr(), cap);
        buf.truncate(n);
        buf
    }

    // T-shim-1: 1000 entries pushed from 8 threads drain completely on the
    // main thread, no duplicates, no losses. Drained in chunks smaller than
    // the total to exercise partial drains.
    #[test]
    fn t_shim_1_thousand_entries_from_eight_threads_drain_completely() {
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        let qaddr = q as usize;
        let mut handles = Vec::new();
        for t in 0..8u64 {
            handles.push(std::thread::spawn(move || {
                let q = qaddr as *mut TemporalioPerlBridgeQueue;
                for i in 0..125u64 {
                    let ud = temporalio_perl_bridge_user_data_new(q, t * 125 + i);
                    unsafe {
                        temporalio_perl_bridge_worker_poll_callback(ud, ptr::null(), ptr::null());
                    }
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        let mut seen = HashSet::new();
        loop {
            let chunk = unsafe { drain_chunk(q, 100) };
            if chunk.is_empty() {
                break;
            }
            for e in &chunk {
                assert!(
                    seen.insert(e.callback_id),
                    "duplicate callback_id {}",
                    e.callback_id
                );
            }
        }
        assert_eq!(seen.len(), 1000, "all 1000 entries must arrive");
        assert!(seen.iter().all(|id| *id < 1000));
        unsafe {
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // T-shim-2 (eventfd half): the signal fd is written exactly once per
    // push — after 5 pushes the eventfd counter reads 5.
    #[cfg(target_os = "linux")]
    #[test]
    fn t_shim_2_eventfd_written_exactly_once_per_push() {
        let fd = nonblocking_eventfd();
        let q = temporalio_perl_bridge_queue_new(fd);
        for id in 0..5u64 {
            let ud = temporalio_perl_bridge_user_data_new(q, id);
            unsafe { temporalio_perl_bridge_worker_callback(ud, ptr::null()) };
        }
        let mut counter = 0u64;
        let n = unsafe { libc::read(fd, &mut counter as *mut u64 as *mut c_void, 8) };
        assert_eq!(n, 8, "eventfd read failed");
        assert_eq!(counter, 5, "eventfd must be written exactly once per push");
        let entries = unsafe { drain_chunk(q, 16) };
        assert_eq!(entries.len(), 5);
        unsafe {
            temporalio_perl_bridge_queue_free(q);
            libc::close(fd);
        }
    }

    // T-shim-2 (EAGAIN half): when the signal write would block it is NOT
    // retried — the signal is dropped, the entry stays queued, and the push
    // returns promptly.
    #[test]
    fn t_shim_2_full_pipe_eagain_is_not_retried_entry_still_queued() {
        let (r, w) = nonblocking_pipe();
        // Fill the pipe to capacity so the next signal write hits EAGAIN.
        let junk = [0u8; 4096];
        let mut filled: usize = 0;
        loop {
            let n = unsafe { libc::write(w, junk.as_ptr() as *const c_void, junk.len()) };
            if n < 0 {
                let err = std::io::Error::last_os_error();
                assert_eq!(err.kind(), std::io::ErrorKind::WouldBlock);
                break;
            }
            filled += n as usize;
        }
        let q = temporalio_perl_bridge_queue_new(w);
        let ud = temporalio_perl_bridge_user_data_new(q, 99);
        // Must return promptly (a retry loop on a full pipe would never).
        unsafe { temporalio_perl_bridge_worker_callback(ud, ptr::null()) };
        // The entry is queued despite the dropped signal.
        let entries = unsafe { drain_chunk(q, 4) };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].callback_id, 99);
        // Only the filler bytes are on the pipe — no retried signal bytes.
        let mut drained: usize = 0;
        let mut buf = [0u8; 4096];
        loop {
            let n = unsafe { libc::read(r, buf.as_mut_ptr() as *mut c_void, buf.len()) };
            if n <= 0 {
                break;
            }
            drained += n as usize;
        }
        assert_eq!(
            drained, filled,
            "EAGAIN signal write must be dropped, not retried"
        );
        unsafe {
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // T-shim-3: queue_free with pending entries drops them all — no crash,
    // no leak (leaks/double-frees would surface under miri/asan).
    #[test]
    fn t_shim_3_queue_free_with_pending_entries_is_clean() {
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        for id in 0..10u64 {
            let ud = temporalio_perl_bridge_user_data_new(q, id);
            unsafe { temporalio_perl_bridge_worker_callback(ud, ptr::null()) };
        }
        unsafe {
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // T-shim-4: pipe fallback — when signal_fd is a pipe write-end the shim
    // writes exactly one byte per push and the queue semantics match the
    // eventfd path (entry per push, signal per push, drain returns entries).
    #[test]
    fn t_shim_4_pipe_fallback_one_byte_per_push_same_semantics() {
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        let ud = temporalio_perl_bridge_user_data_new(q, 7);
        unsafe { temporalio_perl_bridge_worker_callback(ud, ptr::null()) };
        let mut buf = [0u8; 16];
        let n = unsafe { libc::read(r, buf.as_mut_ptr() as *mut c_void, buf.len()) };
        assert_eq!(n, 1, "pipe fallback writes exactly one byte per push");
        let entries = unsafe { drain_chunk(q, 4) };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].callback_id, 7);
        assert_eq!(entries[0].kind, TEMPORALIO_PERL_BRIDGE_KIND_WORKER);
        // A subsequent push signals again.
        let ud2 = temporalio_perl_bridge_user_data_new(q, 8);
        unsafe { temporalio_perl_bridge_worker_callback(ud2, ptr::null()) };
        let n = unsafe { libc::read(r, buf.as_mut_ptr() as *mut c_void, buf.len()) };
        assert_eq!(n, 1);
        let entries = unsafe { drain_chunk(q, 4) };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].callback_id, 8);
        unsafe {
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // user_data pair routing: each pair routes its completion to its own
    // queue with its own callback_id; the pair is single-shot (freed by the
    // trampoline — a double-free would surface under miri/asan).
    #[test]
    fn user_data_pair_routes_to_its_own_queue_and_is_single_shot() {
        let (r1, w1) = nonblocking_pipe();
        let (r2, w2) = nonblocking_pipe();
        let q1 = temporalio_perl_bridge_queue_new(w1);
        let q2 = temporalio_perl_bridge_queue_new(w2);
        let ud1 = temporalio_perl_bridge_user_data_new(q1, 42);
        let ud2 = temporalio_perl_bridge_user_data_new(q2, 7);
        unsafe {
            temporalio_perl_bridge_worker_poll_callback(ud1, ptr::null(), ptr::null());
            temporalio_perl_bridge_worker_poll_callback(ud2, ptr::null(), ptr::null());
        }
        let e1 = unsafe { drain_chunk(q1, 4) };
        assert_eq!(e1.len(), 1);
        assert_eq!(e1[0].callback_id, 42, "entry with id 42 routes to queue 1");
        let e2 = unsafe { drain_chunk(q2, 4) };
        assert_eq!(e2.len(), 1);
        assert_eq!(e2[0].callback_id, 7, "entry with id 7 routes to queue 2");
        assert!(unsafe { drain_chunk(q1, 4) }.is_empty());
        assert!(unsafe { drain_chunk(q2, 4) }.is_empty());
        unsafe {
            temporalio_perl_bridge_queue_free(q1);
            temporalio_perl_bridge_queue_free(q2);
            libc::close(r1);
            libc::close(w1);
            libc::close(r2);
            libc::close(w2);
        }
    }

    // Each trampoline sets kind (1..6 in spec order) and maps its arguments
    // onto the right Entry fields. Sentinel addresses prove the shim treats
    // every pointer as borrowed and never dereferences it.
    #[test]
    fn trampolines_set_kind_and_fields_per_shape() {
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        let s_ba = 0x1000usize as *const TemporalCoreByteArray;
        let f_ba = 0x2000usize as *const TemporalCoreByteArray;
        let det_ba = 0x3000usize as *const TemporalCoreByteArray;
        let tgt_ba = 0x4000usize as *const TemporalCoreByteArray;
        let conn = 0x5000usize as *mut TemporalCoreConnection;
        let srv = 0x6000usize as *mut TemporalCoreEphemeralServer;

        unsafe {
            temporalio_perl_bridge_worker_poll_callback(
                temporalio_perl_bridge_user_data_new(q, 1),
                s_ba,
                f_ba,
            );
            temporalio_perl_bridge_worker_callback(
                temporalio_perl_bridge_user_data_new(q, 2),
                f_ba,
            );
            temporalio_perl_bridge_client_connect_callback(
                temporalio_perl_bridge_user_data_new(q, 3),
                conn,
                f_ba,
            );
            temporalio_perl_bridge_client_rpc_call_callback(
                temporalio_perl_bridge_user_data_new(q, 4),
                s_ba,
                5,
                f_ba,
                det_ba,
            );
            temporalio_perl_bridge_ephemeral_server_start_callback(
                temporalio_perl_bridge_user_data_new(q, 5),
                srv,
                tgt_ba,
                f_ba,
            );
            temporalio_perl_bridge_ephemeral_server_shutdown_callback(
                temporalio_perl_bridge_user_data_new(q, 6),
                f_ba,
            );
        }
        let entries = unsafe { drain_chunk(q, 8) };
        assert_eq!(entries.len(), 6);
        // Single-producer pushes drain in FIFO order.
        let e = &entries[0];
        assert_eq!((e.callback_id, e.kind), (1, TEMPORALIO_PERL_BRIDGE_KIND_WORKER_POLL));
        assert_eq!(e.success_ba, s_ba);
        assert_eq!(e.fail_ba, f_ba);
        assert!(e.success_handle.is_null());

        let e = &entries[1];
        assert_eq!((e.callback_id, e.kind), (2, TEMPORALIO_PERL_BRIDGE_KIND_WORKER));
        assert!(e.success_ba.is_null());
        assert_eq!(e.fail_ba, f_ba);

        let e = &entries[2];
        assert_eq!((e.callback_id, e.kind), (3, TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_CONNECT));
        assert_eq!(e.success_handle, conn as *mut c_void);
        assert_eq!(e.fail_ba, f_ba);
        assert!(e.success_ba.is_null());

        let e = &entries[3];
        assert_eq!((e.callback_id, e.kind), (4, TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_RPC_CALL));
        assert_eq!(e.success_ba, s_ba);
        assert_eq!(e.rpc_status_code, 5);
        assert_eq!(e.fail_ba, f_ba, "rpc failure_message rides in fail_ba");
        assert_eq!(e.rpc_failure_details, det_ba);

        let e = &entries[4];
        assert_eq!(
            (e.callback_id, e.kind),
            (5, TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_START)
        );
        assert_eq!(e.success_handle, srv as *mut c_void);
        assert_eq!(e.ephemeral_target, tgt_ba);
        assert_eq!(e.fail_ba, f_ba);

        let e = &entries[5];
        assert_eq!(
            (e.callback_id, e.kind),
            (6, TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_SHUTDOWN)
        );
        assert_eq!(e.fail_ba, f_ba);

        unsafe {
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // The six *_callback_ptr accessors return the matching trampoline's
    // address — non-null and all distinct.
    #[test]
    fn callback_ptr_accessors_return_their_trampoline_addresses() {
        let ptrs = [
            temporalio_perl_bridge_worker_poll_callback_ptr(),
            temporalio_perl_bridge_worker_callback_ptr(),
            temporalio_perl_bridge_client_connect_callback_ptr(),
            temporalio_perl_bridge_client_rpc_call_callback_ptr(),
            temporalio_perl_bridge_ephemeral_server_start_callback_ptr(),
            temporalio_perl_bridge_ephemeral_server_shutdown_callback_ptr(),
        ];
        for p in ptrs {
            assert!(!p.is_null());
        }
        let distinct: HashSet<usize> = ptrs.iter().map(|p| *p as usize).collect();
        assert_eq!(distinct.len(), 6, "accessors must return distinct pointers");
        let expected = [
            temporalio_perl_bridge_worker_poll_callback as *const (),
            temporalio_perl_bridge_worker_callback as *const (),
            temporalio_perl_bridge_client_connect_callback as *const (),
            temporalio_perl_bridge_client_rpc_call_callback as *const (),
            temporalio_perl_bridge_ephemeral_server_start_callback as *const (),
            temporalio_perl_bridge_ephemeral_server_shutdown_callback as *const (),
        ];
        for (i, (got, want)) in ptrs.iter().zip(expected).enumerate() {
            assert_eq!(
                *got as usize, want as usize,
                "accessor {i} must return its trampoline's address"
            );
        }
    }

    // build.rs must generate the cbindgen header with the full spec
    // section 3 C ABI surface.
    #[test]
    fn generated_header_declares_the_c_abi() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/include/temporalio-perl-bridge.h"
        );
        let header =
            std::fs::read_to_string(path).expect("build.rs must generate the cbindgen header");
        for sym in [
            "TemporalioPerlBridgeEntry",
            "TemporalioPerlBridgeQueue",
            "temporalio_perl_bridge_queue_new",
            "temporalio_perl_bridge_queue_free",
            "temporalio_perl_bridge_user_data_new",
            "temporalio_perl_bridge_queue_drain",
            "temporalio_perl_bridge_worker_poll_callback",
            "temporalio_perl_bridge_worker_callback",
            "temporalio_perl_bridge_client_connect_callback",
            "temporalio_perl_bridge_client_rpc_call_callback",
            "temporalio_perl_bridge_ephemeral_server_start_callback",
            "temporalio_perl_bridge_ephemeral_server_shutdown_callback",
            "temporalio_perl_bridge_worker_poll_callback_ptr",
            "temporalio_perl_bridge_worker_callback_ptr",
            "temporalio_perl_bridge_client_connect_callback_ptr",
            "temporalio_perl_bridge_client_rpc_call_callback_ptr",
            "temporalio_perl_bridge_ephemeral_server_start_callback_ptr",
            "temporalio_perl_bridge_ephemeral_server_shutdown_callback_ptr",
            "temporalio_perl_bridge_debug_worker_options",
            "temporalio_perl_bridge_string_free",
            "temporalio_perl_bridge_forwarded_log_callback",
            "temporalio_perl_bridge_forwarded_log_callback_ptr",
            "temporalio_perl_bridge_forwarded_log_free",
            "temporalio_perl_bridge_forwarding_register",
            "temporalio_perl_bridge_forwarding_unregister",
            // Custom metric meter (spec section 28.2).
            "temporalio_perl_bridge_meter_register",
            "temporalio_perl_bridge_meter_unregister",
            "temporalio_perl_bridge_meter_metric_new_ptr",
            "temporalio_perl_bridge_meter_metric_free_ptr",
            "temporalio_perl_bridge_meter_record_integer_ptr",
            "temporalio_perl_bridge_meter_record_float_ptr",
            "temporalio_perl_bridge_meter_record_duration_ptr",
            "temporalio_perl_bridge_meter_attributes_new_ptr",
            "temporalio_perl_bridge_meter_attributes_free_ptr",
            "temporalio_perl_bridge_meter_meter_free_ptr",
            "temporalio_perl_bridge_meter_next_request",
            "temporalio_perl_bridge_meter_free_request",
            "temporalio_perl_bridge_meter_drain_records",
            "temporalio_perl_bridge_meter_req_name",
            "temporalio_perl_bridge_meter_req_kind",
            "temporalio_perl_bridge_meter_req_new_id",
            "temporalio_perl_bridge_meter_req_free_id",
            "temporalio_perl_bridge_meter_req_attr_count",
            "TemporalioPerlBridgeMeterRecord",
        ] {
            assert!(header.contains(sym), "header missing {sym}");
        }
        // The WorkerOptions tree belongs to temporal-sdk-core-c-bridge.h:
        // the shim header must carry only a forward typedef, never a
        // conflicting definition (cbindgen [export] exclude).
        assert!(
            header.contains(
                "typedef struct TemporalCoreWorkerOptions TemporalCoreWorkerOptions;"
            ),
            "header missing the TemporalCoreWorkerOptions forward typedef"
        );
        assert!(
            !header.contains("} TemporalCoreWorkerOptions;"),
            "header must not define the TemporalCoreWorkerOptions struct body"
        );
    }

    // ---- P0.10 / risk spike 3: debug_worker_options echo ------------------

    fn baref(s: &str) -> TemporalCoreByteArrayRef {
        TemporalCoreByteArrayRef {
            data: s.as_ptr(),
            size: s.len(),
        }
    }

    fn baref_null() -> TemporalCoreByteArrayRef {
        TemporalCoreByteArrayRef {
            data: ptr::null(),
            size: 0,
        }
    }

    fn fixed(n: usize) -> TemporalCoreSlotSupplier {
        TemporalCoreSlotSupplier::FixedSize(TemporalCoreFixedSizeSlotSupplier { num_slots: n })
    }

    unsafe fn debug_summary(options: *const TemporalCoreWorkerOptions) -> String {
        let raw = temporalio_perl_bridge_debug_worker_options(options);
        assert!(!raw.is_null(), "debug_worker_options returned null");
        let summary = std::ffi::CStr::from_ptr(raw)
            .to_str()
            .expect("summary must be UTF-8")
            .to_owned();
        temporalio_perl_bridge_string_free(raw);
        summary
    }

    // The echo summary covers EVERY WorkerOptions field, in struct order,
    // for the exact configuration the v0.1 SDK passes (spec section 8.1):
    // versioning None{build_id}, four FixedSize suppliers, simple-maximum
    // pollers, empty trailing arrays.
    #[test]
    fn debug_worker_options_echoes_the_v01_configuration_field_for_field() {
        let sm5 = TemporalCorePollerBehaviorSimpleMaximum { simple_maximum: 5 };
        let options = TemporalCoreWorkerOptions {
            namespace: baref("default-ns"),
            task_queue: baref("spike-tq"),
            versioning_strategy: TemporalCoreWorkerVersioningStrategy::None(
                TemporalCoreWorkerVersioningNone {
                    build_id: baref("b1"),
                },
            ),
            identity_override: baref_null(),
            max_cached_workflows: 1000,
            tuner: TemporalCoreTunerHolder {
                workflow_slot_supplier: fixed(100),
                activity_slot_supplier: fixed(100),
                local_activity_slot_supplier: fixed(100),
                nexus_task_slot_supplier: fixed(100),
            },
            task_types: TemporalCoreWorkerTaskTypes {
                enable_workflows: true,
                enable_local_activities: false,
                enable_remote_activities: true,
                enable_nexus: false,
            },
            sticky_queue_schedule_to_start_timeout_millis: 10000,
            max_heartbeat_throttle_interval_millis: 60000,
            default_heartbeat_throttle_interval_millis: 30000,
            max_activities_per_second: 0.0,
            max_task_queue_activities_per_second: 0.0,
            graceful_shutdown_period_millis: 0,
            workflow_task_poller_behavior: TemporalCorePollerBehavior {
                simple_maximum: &sm5,
                autoscaling: ptr::null(),
            },
            nonsticky_to_sticky_poll_ratio: 0.2,
            activity_task_poller_behavior: TemporalCorePollerBehavior {
                simple_maximum: &sm5,
                autoscaling: ptr::null(),
            },
            nexus_task_poller_behavior: TemporalCorePollerBehavior {
                simple_maximum: &sm5,
                autoscaling: ptr::null(),
            },
            nondeterminism_as_workflow_fail: false,
            nondeterminism_as_workflow_fail_for_types: TemporalCoreByteArrayRefArray {
                data: ptr::null(),
                size: 0,
            },
            plugins: TemporalCoreByteArrayRefArray {
                data: ptr::null(),
                size: 0,
            },
            storage_drivers: TemporalCoreByteArrayRefArray {
                data: ptr::null(),
                size: 0,
            },
        };
        let expected = "\
namespace=default-ns
task_queue=spike-tq
versioning_strategy.tag=None
versioning_strategy.none.build_id=b1
identity_override=<null>
max_cached_workflows=1000
tuner.workflow_slot_supplier=FixedSize(100)
tuner.activity_slot_supplier=FixedSize(100)
tuner.local_activity_slot_supplier=FixedSize(100)
tuner.nexus_task_slot_supplier=FixedSize(100)
task_types.enable_workflows=true
task_types.enable_local_activities=false
task_types.enable_remote_activities=true
task_types.enable_nexus=false
sticky_queue_schedule_to_start_timeout_millis=10000
max_heartbeat_throttle_interval_millis=60000
default_heartbeat_throttle_interval_millis=30000
max_activities_per_second=0
max_task_queue_activities_per_second=0
graceful_shutdown_period_millis=0
workflow_task_poller_behavior=simple_maximum(5)
nonsticky_to_sticky_poll_ratio=0.2
activity_task_poller_behavior=simple_maximum(5)
nexus_task_poller_behavior=simple_maximum(5)
nondeterminism_as_workflow_fail=false
nondeterminism_as_workflow_fail_for_types=[]
plugins=[]
storage_drivers=[]
";
        let summary = unsafe { debug_summary(&options) };
        assert_eq!(summary, expected);
    }

    // The other union variants echo their own fields: DeploymentBased and
    // LegacyBuildIdBased versioning, ResourceBased and Custom suppliers,
    // autoscaling and absent poller behaviors, populated ref arrays.
    #[test]
    fn debug_worker_options_echoes_alternate_union_variants() {
        let auto = TemporalCorePollerBehaviorAutoscaling {
            minimum: 1,
            maximum: 100,
            initial: 5,
        };
        let types = [baref("My::Err"), baref("Other::Err")];
        let mut options = TemporalCoreWorkerOptions {
            namespace: baref("ns2"),
            task_queue: baref("tq2"),
            versioning_strategy: TemporalCoreWorkerVersioningStrategy::DeploymentBased(
                TemporalCoreWorkerDeploymentOptions {
                    version: TemporalCoreWorkerDeploymentVersion {
                        deployment_name: baref("dep-1"),
                        build_id: baref("b2"),
                    },
                    use_worker_versioning: true,
                    default_versioning_behavior: 2,
                },
            ),
            identity_override: baref("me@host"),
            max_cached_workflows: 42,
            tuner: TemporalCoreTunerHolder {
                workflow_slot_supplier: TemporalCoreSlotSupplier::ResourceBased(
                    TemporalCoreResourceBasedSlotSupplier {
                        minimum_slots: 1,
                        maximum_slots: 10,
                        ramp_throttle_ms: 50,
                        tuner_options: TemporalCoreResourceBasedTunerOptions {
                            target_memory_usage: 0.5,
                            target_cpu_usage: 0.9,
                        },
                    },
                ),
                activity_slot_supplier: TemporalCoreSlotSupplier::Custom(
                    TemporalCoreCustomSlotSupplierCallbacksImpl(ptr::null()),
                ),
                local_activity_slot_supplier: fixed(13),
                nexus_task_slot_supplier: fixed(17),
            },
            task_types: TemporalCoreWorkerTaskTypes {
                enable_workflows: false,
                enable_local_activities: true,
                enable_remote_activities: false,
                enable_nexus: true,
            },
            sticky_queue_schedule_to_start_timeout_millis: 1,
            max_heartbeat_throttle_interval_millis: 2,
            default_heartbeat_throttle_interval_millis: 3,
            max_activities_per_second: 1.5,
            max_task_queue_activities_per_second: 2.25,
            graceful_shutdown_period_millis: 5000,
            workflow_task_poller_behavior: TemporalCorePollerBehavior {
                simple_maximum: ptr::null(),
                autoscaling: &auto,
            },
            nonsticky_to_sticky_poll_ratio: 0.25,
            activity_task_poller_behavior: TemporalCorePollerBehavior {
                simple_maximum: ptr::null(),
                autoscaling: ptr::null(),
            },
            nexus_task_poller_behavior: TemporalCorePollerBehavior {
                simple_maximum: ptr::null(),
                autoscaling: &auto,
            },
            nondeterminism_as_workflow_fail: true,
            nondeterminism_as_workflow_fail_for_types: TemporalCoreByteArrayRefArray {
                data: types.as_ptr(),
                size: types.len(),
            },
            plugins: TemporalCoreByteArrayRefArray {
                data: ptr::null(),
                size: 0,
            },
            storage_drivers: TemporalCoreByteArrayRefArray {
                data: ptr::null(),
                size: 0,
            },
        };
        let summary = unsafe { debug_summary(&options) };
        for line in [
            "versioning_strategy.tag=DeploymentBased",
            "versioning_strategy.deployment.deployment_name=dep-1",
            "versioning_strategy.deployment.build_id=b2",
            "versioning_strategy.deployment.use_worker_versioning=true",
            "versioning_strategy.deployment.default_versioning_behavior=2",
            "identity_override=me@host",
            "tuner.workflow_slot_supplier=ResourceBased(min=1,max=10,ramp_ms=50,mem=0.5,cpu=0.9)",
            "tuner.activity_slot_supplier=Custom",
            "tuner.local_activity_slot_supplier=FixedSize(13)",
            "tuner.nexus_task_slot_supplier=FixedSize(17)",
            "max_activities_per_second=1.5",
            "max_task_queue_activities_per_second=2.25",
            "workflow_task_poller_behavior=autoscaling(min=1,max=100,initial=5)",
            "nonsticky_to_sticky_poll_ratio=0.25",
            "activity_task_poller_behavior=<none>",
            "nondeterminism_as_workflow_fail=true",
            "nondeterminism_as_workflow_fail_for_types=[My::Err,Other::Err]",
        ] {
            assert!(
                summary.lines().any(|l| l == line),
                "summary missing line {line:?}; got:\n{summary}"
            );
        }
        options.versioning_strategy = TemporalCoreWorkerVersioningStrategy::LegacyBuildIdBased(
            TemporalCoreLegacyBuildIdBasedStrategy {
                build_id: baref("lb"),
            },
        );
        let summary = unsafe { debug_summary(&options) };
        for line in [
            "versioning_strategy.tag=LegacyBuildIdBased",
            "versioning_strategy.legacy.build_id=lb",
        ] {
            assert!(
                summary.lines().any(|l| l == line),
                "summary missing line {line:?}; got:\n{summary}"
            );
        }
    }

    // A null options pointer echoes a sentinel instead of crashing.
    #[test]
    fn debug_worker_options_null_pointer_is_safe() {
        let summary = unsafe { debug_summary(ptr::null()) };
        assert_eq!(summary, "options=<null>\n");
    }

    // ---- P10.3 / spec section 28.1: log forwarding (kind 7) ----------------
    //
    // The shim calls core's forwarded-log accessors; the cargo test binary
    // does not link the core bridge, so we supply our own `#[no_mangle]`
    // definitions backed by a test-owned struct. The struct's strings are
    // freed the instant the trampoline returns (mirroring core's "log is freed
    // immediately after the callback") so the deep-copy assertion (T-logfwd-3)
    // genuinely catches a use-after-free.

    struct TestForwardedLog {
        target: String,
        message: String,
        fields_json: String,
        timestamp_ms: u64,
    }

    fn test_log_ref(s: &str) -> ForwardedLogByteArrayRef {
        ForwardedLogByteArrayRef {
            data: s.as_ptr(),
            size: s.len(),
        }
    }

    #[no_mangle]
    extern "C" fn temporal_core_forwarded_log_target(
        log: *const TemporalCoreForwardedLog,
    ) -> ForwardedLogByteArrayRef {
        let log = unsafe { &*log.cast::<TestForwardedLog>() };
        test_log_ref(&log.target)
    }

    #[no_mangle]
    extern "C" fn temporal_core_forwarded_log_message(
        log: *const TemporalCoreForwardedLog,
    ) -> ForwardedLogByteArrayRef {
        let log = unsafe { &*log.cast::<TestForwardedLog>() };
        test_log_ref(&log.message)
    }

    #[no_mangle]
    extern "C" fn temporal_core_forwarded_log_timestamp_millis(
        log: *const TemporalCoreForwardedLog,
    ) -> u64 {
        let log = unsafe { &*log.cast::<TestForwardedLog>() };
        log.timestamp_ms
    }

    #[no_mangle]
    extern "C" fn temporal_core_forwarded_log_fields_json(
        log: *const TemporalCoreForwardedLog,
    ) -> ForwardedLogByteArrayRef {
        let log = unsafe { &*log.cast::<TestForwardedLog>() };
        test_log_ref(&log.fields_json)
    }

    unsafe fn cstr(ptr: *mut c_char) -> String {
        std::ffi::CStr::from_ptr(ptr).to_str().unwrap().to_owned()
    }

    // Serialize the registry-claiming tests: the forwarding registry is a
    // single process-global, and cargo runs tests on multiple threads.
    static FORWARDING_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    // Claim the registry for `q` with the test accessor function pointers.
    fn register_test_accessors(q: *mut TemporalioPerlBridgeQueue) -> bool {
        unsafe {
            temporalio_perl_bridge_forwarding_register(
                q,
                temporal_core_forwarded_log_target as *const c_void,
                temporal_core_forwarded_log_message as *const c_void,
                temporal_core_forwarded_log_timestamp_millis as *const c_void,
                temporal_core_forwarded_log_fields_json as *const c_void,
            )
        }
    }

    // T-logfwd-3: the trampoline deep-copies every field, so the entry stays
    // intact after the source log (and its backing strings) are freed. The
    // test frees the TestForwardedLog before reading the drained entry; a
    // shallow copy would read freed memory (caught under ASan/miri).
    #[test]
    fn t_logfwd_3_trampoline_deep_copies_log_surviving_immediate_free() {
        let _guard = FORWARDING_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_accessors(q));

        {
            // Box the log so it has a stable address, then drop it right after
            // the trampoline returns — exactly core's lifetime contract.
            let log = Box::new(TestForwardedLog {
                target: "temporal_sdk_core::worker".to_owned(),
                message: "polling for tasks".to_owned(),
                fields_json: r#"{"attempt":3,"run_id":"abc"}"#.to_owned(),
                timestamp_ms: 1_700_000_000_123,
            });
            let log_ptr = (&*log as *const TestForwardedLog).cast::<TemporalCoreForwardedLog>();
            unsafe {
                // 3 = Warn (ForwardedLogLevel Trace=0..Error=4).
                temporalio_perl_bridge_forwarded_log_callback(3, log_ptr);
            }
            drop(log); // free the source before reading the deep copy
        }

        let entries = unsafe { drain_chunk(q, 4) };
        assert_eq!(entries.len(), 1);
        let e = &entries[0];
        assert_eq!(e.kind, TEMPORALIO_PERL_BRIDGE_KIND_FORWARDED_LOG);
        assert_eq!(e.log_timestamp_ms, 1_700_000_000_123);
        unsafe {
            assert_eq!(cstr(e.log_target), "temporal_sdk_core::worker");
            assert_eq!(cstr(e.log_message), "polling for tasks");
            assert_eq!(cstr(e.log_fields_json), r#"{"attempt":3,"run_id":"abc"}"#);
        }
        // Free the drained entry's buffers (the Perl drain's job), then a
        // second free is a no-op (idempotent).
        unsafe {
            let ep = &entries[0] as *const _ as *mut TemporalioPerlBridgeEntry;
            temporalio_perl_bridge_forwarded_log_free(ep);
            temporalio_perl_bridge_forwarded_log_free(ep);
        }
        unsafe {
            temporalio_perl_bridge_forwarding_unregister(q);
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // The level argument rides in rpc_status_code unchanged (0..4).
    #[test]
    fn t_logfwd_level_rides_in_status_code() {
        let _guard = FORWARDING_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_accessors(q));
        let log = Box::new(TestForwardedLog {
            target: "t".to_owned(),
            message: "m".to_owned(),
            fields_json: "{}".to_owned(),
            timestamp_ms: 1,
        });
        let log_ptr = (&*log as *const TestForwardedLog).cast::<TemporalCoreForwardedLog>();
        unsafe {
            // 4 = Error
            temporalio_perl_bridge_forwarded_log_callback(4, log_ptr);
        }
        let entries = unsafe { drain_chunk(q, 4) };
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].rpc_status_code, 4);
        unsafe {
            let ep = &entries[0] as *const _ as *mut TemporalioPerlBridgeEntry;
            temporalio_perl_bridge_forwarded_log_free(ep);
            temporalio_perl_bridge_forwarding_unregister(q);
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // T-logfwd-5: queue_free with N undrained kind-7 entries frees their
    // shim-owned buffers via Entry::drop — no leak, no crash (surfaced under
    // miri/ASan). The drop must run exactly once per buffer.
    #[test]
    fn t_logfwd_5_shutdown_frees_undrained_forwarded_log_entries() {
        let _guard = FORWARDING_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_accessors(q));
        for i in 0..5u64 {
            let log = Box::new(TestForwardedLog {
                target: format!("target-{i}"),
                message: format!("message-{i}"),
                fields_json: "{}".to_owned(),
                timestamp_ms: i,
            });
            let log_ptr =
                (&*log as *const TestForwardedLog).cast::<TemporalCoreForwardedLog>();
            unsafe {
                temporalio_perl_bridge_forwarded_log_callback(2, log_ptr);
            }
        }
        // Never drained: queue_free must drop all 5 entries and their buffers.
        unsafe {
            temporalio_perl_bridge_forwarding_unregister(q);
            temporalio_perl_bridge_queue_free(q);
            libc::close(r);
            libc::close(w);
        }
    }

    // A second runtime requesting forwarding while one is active is refused
    // (the Perl side turns the false return into Argument). Unregister frees
    // the slot for a later runtime.
    #[test]
    fn forwarding_register_is_single_owner() {
        let _guard = FORWARDING_TEST_LOCK.lock().unwrap();
        let (r1, w1) = nonblocking_pipe();
        let (r2, w2) = nonblocking_pipe();
        let q1 = temporalio_perl_bridge_queue_new(w1);
        let q2 = temporalio_perl_bridge_queue_new(w2);
        assert!(register_test_accessors(q1));
        assert!(
            !register_test_accessors(q2),
            "second forwarder must be refused while one is active"
        );
        // A non-owner unregister is a no-op (q2 never registered).
        temporalio_perl_bridge_forwarding_unregister(q2);
        assert!(
            !register_test_accessors(q2),
            "registry still held by q1"
        );
        temporalio_perl_bridge_forwarding_unregister(q1);
        assert!(
            register_test_accessors(q2),
            "registry free after q1 unregisters"
        );
        temporalio_perl_bridge_forwarding_unregister(q2);
        unsafe {
            temporalio_perl_bridge_queue_free(q1);
            temporalio_perl_bridge_queue_free(q2);
            libc::close(r1);
            libc::close(w1);
            libc::close(r2);
            libc::close(w2);
        }
    }

    // A null registry (no forwarder, or torn down mid-flight) drops the log
    // instead of crashing.
    #[test]
    fn forwarded_log_with_no_registry_is_dropped() {
        let _guard = FORWARDING_TEST_LOCK.lock().unwrap();
        // Ensure no registry is set.
        assert!(FORWARDING_QUEUE.load(Ordering::Acquire).is_null());
        let log = Box::new(TestForwardedLog {
            target: "t".to_owned(),
            message: "m".to_owned(),
            fields_json: "{}".to_owned(),
            timestamp_ms: 1,
        });
        let log_ptr = (&*log as *const TestForwardedLog).cast::<TemporalCoreForwardedLog>();
        // Must not crash; nothing is queued.
        unsafe { temporalio_perl_bridge_forwarded_log_callback(0, log_ptr) };
    }

    // ---- P10.4 / spec section 28.2: custom metric meters -------------------
    //
    // The meter registry is a single process-global, so the meter tests
    // serialize on this lock (cargo runs tests on multiple threads).
    static METER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn register_test_meter(q: *mut TemporalioPerlBridgeQueue) -> bool {
        unsafe { temporalio_perl_bridge_meter_register(q) }
    }

    unsafe fn unregister_and_free(q: *mut TemporalioPerlBridgeQueue, r: i32, w: i32) {
        temporalio_perl_bridge_meter_unregister(q);
        temporalio_perl_bridge_queue_free(q);
        libc::close(r);
        libc::close(w);
    }

    fn zeroed_meter_records(n: usize) -> Vec<TemporalioPerlBridgeMeterRecord> {
        (0..n)
            .map(|_| TemporalioPerlBridgeMeterRecord {
                metric_id: 0,
                attributes_id: 0,
                record_kind: 0,
                value: 0.0,
                count: 0,
            })
            .collect()
    }

    fn baref_str(s: &str) -> TemporalCoreByteArrayRef {
        TemporalCoreByteArrayRef { data: s.as_ptr(), size: s.len() }
    }

    // Spike resolution (spec section 28.2, M3): metric_new never blocks and
    // never calls Perl — it allocates a handle id and PARKS a create request
    // for the main-thread drain, returning the id immediately. This is correct
    // on any thread (including reentrantly on the main thread), avoiding both
    // self-deadlock and nested FFI re-entry.
    #[test]
    fn t_meter_metric_new_parks_request_returns_id_nonblocking() {
        let _guard = METER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_meter(q));
        let h1 = unsafe {
            temporalio_perl_bridge_meter_metric_new(
                baref_str("temporal_requests"),
                baref_str(""),
                baref_str("requests"),
                1,
            )
        };
        let h2 = unsafe {
            temporalio_perl_bridge_meter_metric_new(
                baref_str("other"),
                baref_str(""),
                baref_str(""),
                5,
            )
        };
        // Distinct, non-null handle ids returned without any drain having run.
        assert!(handle_to_id(h1) != 0 && handle_to_id(h2) != 0);
        assert_ne!(handle_to_id(h1), handle_to_id(h2));
        // Two create requests are parked for the drain; pop and inspect them.
        let mut tag = 0u8;
        let req = unsafe { temporalio_perl_bridge_meter_next_request(&mut tag) };
        assert_eq!(tag, TEMPORALIO_PERL_BRIDGE_METER_REQ_METRIC_NEW);
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_new_id(req) }, handle_to_id(h1));
        let name = unsafe { temporalio_perl_bridge_meter_req_name(req) };
        let s = unsafe {
            std::str::from_utf8(std::slice::from_raw_parts(name.data, name.size)).unwrap()
        };
        assert_eq!(s, "temporal_requests");
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_kind(req) }, 1);
        unsafe { temporalio_perl_bridge_meter_free_request(req) };
        // Second request.
        let req2 = unsafe { temporalio_perl_bridge_meter_next_request(&mut tag) };
        assert!(!req2.is_null());
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_new_id(req2) }, handle_to_id(h2));
        unsafe { temporalio_perl_bridge_meter_free_request(req2) };
        // Queue now empty.
        assert!(unsafe { temporalio_perl_bridge_meter_next_request(&mut tag) }.is_null());
        unsafe { unregister_and_free(q, r, w) };
    }

    // T-meter-7: 8 threads each record 1000 integer values on the same metric;
    // the shim aggregation sums them EXACTLY, with zero Perl contact (records
    // are pure Rust — no request is ever parked by record_*).
    #[test]
    fn t_meter_7_eight_thread_record_aggregates_exactly_no_perl_call() {
        let _guard = METER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_meter(q));
        let metric_addr = id_to_handle(7) as usize;
        let attrs_addr = id_to_handle(3) as usize;
        let mut handles = Vec::new();
        for _ in 0..8u64 {
            handles.push(std::thread::spawn(move || {
                let metric = metric_addr as *const c_void;
                let attrs = attrs_addr as *const c_void;
                for _ in 0..1000u64 {
                    unsafe {
                        temporalio_perl_bridge_meter_record_integer(metric, 1, attrs);
                    }
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        // record_* never parks a request (pure Rust, off-main-thread safe).
        let mut tag = 0u8;
        assert!(unsafe { temporalio_perl_bridge_meter_next_request(&mut tag) }.is_null());
        // Drain the aggregation: one bucket (7,3) summing to 8000, count 8000.
        let mut buf = zeroed_meter_records(16);
        let n = unsafe {
            temporalio_perl_bridge_meter_drain_records(buf.as_mut_ptr(), buf.len())
        };
        assert_eq!(n, 1, "one aggregation bucket");
        assert_eq!(buf[0].metric_id, 7);
        assert_eq!(buf[0].attributes_id, 3);
        assert_eq!(buf[0].record_kind, 1);
        assert_eq!(buf[0].value, 8000.0, "8 threads x 1000 x 1 summed exactly");
        assert_eq!(buf[0].count, 8000);
        // A second drain is empty (records cleared).
        let n2 = unsafe {
            temporalio_perl_bridge_meter_drain_records(buf.as_mut_ptr(), buf.len())
        };
        assert_eq!(n2, 0);
        unsafe { unregister_and_free(q, r, w) };
    }

    // record kinds x value types fold into distinct buckets per record_kind.
    #[test]
    fn t_meter_record_kinds_bucket_by_kind() {
        let _guard = METER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_meter(q));
        let a = id_to_handle(0); // null attrs
        unsafe {
            temporalio_perl_bridge_meter_record_integer(id_to_handle(1), 5, a);
            temporalio_perl_bridge_meter_record_float(id_to_handle(2), 2.5, a);
            temporalio_perl_bridge_meter_record_duration(id_to_handle(3), 100, a);
        }
        let mut buf = zeroed_meter_records(8);
        let n = unsafe {
            temporalio_perl_bridge_meter_drain_records(buf.as_mut_ptr(), buf.len())
        };
        assert_eq!(n, 3, "three distinct metric buckets");
        let mut by_kind: std::collections::HashMap<u8, f64> = std::collections::HashMap::new();
        for rec in &buf[..n] {
            by_kind.insert(rec.record_kind, rec.value);
        }
        assert_eq!(by_kind[&1], 5.0);
        assert_eq!(by_kind[&2], 2.5);
        assert_eq!(by_kind[&3], 100.0);
        unsafe { unregister_and_free(q, r, w) };
    }

    // A null/zero metric handle (Perl will return undef from create_metric)
    // drops the record — nothing aggregates under id 0.
    #[test]
    fn t_meter_null_metric_drops_record() {
        let _guard = METER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_meter(q));
        unsafe {
            temporalio_perl_bridge_meter_record_integer(ptr::null(), 9, ptr::null());
        }
        let mut buf = zeroed_meter_records(4);
        let n = unsafe {
            temporalio_perl_bridge_meter_drain_records(buf.as_mut_ptr(), buf.len())
        };
        assert_eq!(n, 0, "a disabled (null) metric records nothing");
        unsafe { unregister_and_free(q, r, w) };
    }

    // attributes_new decodes the borrowed attribute array into owned copies the
    // drain reads (string/int/float/bool, incl. value types).
    #[test]
    fn t_meter_attributes_new_decodes_value_types() {
        let _guard = METER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_meter(q));
        let (val_s, key_s, key_i, key_f, key_b) =
            ("node-1", "host", "count", "ratio", "ok");
        let attrs = [
            TemporalCoreCustomMetricAttribute {
                key: baref_str(key_s),
                value: TemporalCoreCustomMetricAttributeValue {
                    string_value: TemporalCoreCustomMetricAttributeValueString {
                        data: val_s.as_ptr(),
                        size: val_s.len(),
                    },
                },
                value_type: 1,
            },
            TemporalCoreCustomMetricAttribute {
                key: baref_str(key_i),
                value: TemporalCoreCustomMetricAttributeValue { int_value: 42 },
                value_type: 2,
            },
            TemporalCoreCustomMetricAttribute {
                key: baref_str(key_f),
                value: TemporalCoreCustomMetricAttributeValue { float_value: 0.5 },
                value_type: 3,
            },
            TemporalCoreCustomMetricAttribute {
                key: baref_str(key_b),
                value: TemporalCoreCustomMetricAttributeValue { bool_value: true },
                value_type: 4,
            },
        ];
        let h = unsafe {
            temporalio_perl_bridge_meter_attributes_new(ptr::null(), attrs.as_ptr(), attrs.len())
        };
        assert!(handle_to_id(h) != 0);
        // Pop the parked request and verify the decoded attributes.
        let mut tag = 0u8;
        let req = unsafe { temporalio_perl_bridge_meter_next_request(&mut tag) };
        assert_eq!(tag, TEMPORALIO_PERL_BRIDGE_METER_REQ_ATTRIBUTES_NEW);
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_attr_count(req) }, 4);
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_attr_value_type(req, 0) }, 1);
        let sv = unsafe { temporalio_perl_bridge_meter_req_attr_string(req, 0) };
        let s = unsafe {
            std::str::from_utf8(std::slice::from_raw_parts(sv.data, sv.size)).unwrap()
        };
        assert_eq!(s, "node-1");
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_attr_int(req, 1) }, 42);
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_attr_float(req, 2) }, 0.5);
        assert!(unsafe { temporalio_perl_bridge_meter_req_attr_bool(req, 3) });
        unsafe { temporalio_perl_bridge_meter_free_request(req) };
        unsafe { unregister_and_free(q, r, w) };
    }

    // A second runtime requesting a meter while one is active is refused (Perl
    // turns false into Argument); unregister frees the slot.
    #[test]
    fn t_meter_register_is_single_owner() {
        let _guard = METER_TEST_LOCK.lock().unwrap();
        let (r1, w1) = nonblocking_pipe();
        let (r2, w2) = nonblocking_pipe();
        let q1 = temporalio_perl_bridge_queue_new(w1);
        let q2 = temporalio_perl_bridge_queue_new(w2);
        assert!(register_test_meter(q1));
        assert!(!register_test_meter(q2), "second meter refused while one active");
        unsafe { temporalio_perl_bridge_meter_unregister(q2) }; // non-owner no-op
        assert!(!register_test_meter(q2), "still held by q1");
        unsafe { temporalio_perl_bridge_meter_unregister(q1) };
        assert!(register_test_meter(q2), "free after q1 unregisters");
        unsafe {
            temporalio_perl_bridge_meter_unregister(q2);
            temporalio_perl_bridge_queue_free(q1);
            temporalio_perl_bridge_queue_free(q2);
            libc::close(r1);
            libc::close(w1);
            libc::close(r2);
            libc::close(w2);
        }
    }

    // Off-main-thread metric_new: identical path (park + return id, no block),
    // proving the design is thread-agnostic. The worker thread gets its id and
    // the request is queued for the drain.
    #[test]
    fn t_meter_off_thread_metric_new_parks_too() {
        let _guard = METER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(register_test_meter(q));
        let worker = std::thread::spawn(move || {
            let name = "off_thread_metric";
            let h = unsafe {
                temporalio_perl_bridge_meter_metric_new(
                    TemporalCoreByteArrayRef { data: name.as_ptr(), size: name.len() },
                    TemporalCoreByteArrayRef { data: ptr::null(), size: 0 },
                    TemporalCoreByteArrayRef { data: ptr::null(), size: 0 },
                    1,
                )
            };
            handle_to_id(h)
        });
        let id = worker.join().unwrap();
        assert!(id != 0, "off-thread metric_new returns a handle id");
        let mut tag = 0u8;
        let req = unsafe { temporalio_perl_bridge_meter_next_request(&mut tag) };
        assert_eq!(tag, TEMPORALIO_PERL_BRIDGE_METER_REQ_METRIC_NEW);
        assert_eq!(unsafe { temporalio_perl_bridge_meter_req_new_id(req) }, id);
        unsafe { temporalio_perl_bridge_meter_free_request(req) };
        unsafe { unregister_and_free(q, r, w) };
    }

    // ---- P10.6 / spec section 29.2: custom slot suppliers ------------------
    //
    // The supplier registry is a single process-global, so these tests
    // serialize on this lock (cargo runs tests multi-threaded).
    static SUPPLIER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    unsafe fn supplier_unregister_and_free(
        q: *mut TemporalioPerlBridgeQueue,
        r: i32,
        w: i32,
    ) {
        temporalio_perl_bridge_supplier_unregister(q);
        temporalio_perl_bridge_queue_free(q);
        libc::close(r);
        libc::close(w);
    }

    fn reserve_ctx(slot_type: i32) -> TemporalCoreSlotReserveCtx {
        TemporalCoreSlotReserveCtx {
            slot_type,
            task_queue: TemporalCoreByteArrayRef { data: ptr::null(), size: 0 },
            worker_identity: TemporalCoreByteArrayRef { data: ptr::null(), size: 0 },
            worker_build_id: TemporalCoreByteArrayRef { data: ptr::null(), size: 0 },
            is_sticky: false,
        }
    }

    // The reserve/mark_used/release callbacks fire on a worker thread and PARK
    // requests onto the per-runtime queue; the main thread drains them. Each
    // request carries the supplier id, the slot type, and (for release) the
    // permit. try_reserve returns 0 (declines) and still parks for observation.
    #[test]
    fn t_tuner_supplier_callbacks_park_off_thread_and_drain() {
        let _guard = SUPPLIER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(unsafe { temporalio_perl_bridge_supplier_register(q) });

        // Build a supplier; its callbacks struct user_data is the supplier id.
        let cb_ptr = unsafe { temporalio_perl_bridge_supplier_new() } as *const _
            as *const TemporalCoreCustomSlotSupplierCallbacks;
        assert!(!cb_ptr.is_null(), "supplier_new returns a callbacks pointer");
        let supplier_id = unsafe { (*cb_ptr).user_data } as u64;
        assert!(supplier_id != 0, "supplier id is non-zero");

        // Fire reserve on a separate thread (mirrors a Tokio core thread).
        let cb_addr = cb_ptr as usize;
        std::thread::spawn(move || {
            let cb = cb_addr as *const TemporalCoreCustomSlotSupplierCallbacks;
            let ctx = reserve_ctx(1); // ActivitySlotKindType
            let completion = 0xDEAD_BEEFusize as *const c_void;
            unsafe { ((*cb).reserve)(&ctx, completion, (*cb).user_data) };
        })
        .join()
        .unwrap();

        // try_reserve returns 0 (declines) and parks a request.
        let try_permit = unsafe {
            let ctx = reserve_ctx(0);
            ((*cb_ptr).try_reserve)(&ctx, (*cb_ptr).user_data)
        };
        assert_eq!(try_permit, 0, "try_reserve declines (returns 0)");

        // Drain the two parked requests on the main thread.
        let mut tag = 0u8;
        let req1 = unsafe { temporalio_perl_bridge_supplier_next_request(&mut tag) };
        assert!(!req1.is_null());
        assert_eq!(tag, TEMPORALIO_PERL_BRIDGE_SLOT_REQ_RESERVE);
        assert_eq!(
            unsafe { temporalio_perl_bridge_slot_req_supplier_id(req1) },
            supplier_id
        );
        assert_eq!(unsafe { temporalio_perl_bridge_slot_req_slot_type(req1) }, 1);
        assert_eq!(
            unsafe { temporalio_perl_bridge_slot_req_completion_ctx(req1) } as usize,
            0xDEAD_BEEFusize
        );
        unsafe { temporalio_perl_bridge_supplier_free_request(req1) };

        let req2 = unsafe { temporalio_perl_bridge_supplier_next_request(&mut tag) };
        assert!(!req2.is_null());
        assert_eq!(tag, TEMPORALIO_PERL_BRIDGE_SLOT_REQ_TRY_RESERVE);
        unsafe { temporalio_perl_bridge_supplier_free_request(req2) };

        // No more parked requests.
        let req3 = unsafe { temporalio_perl_bridge_supplier_next_request(&mut tag) };
        assert!(req3.is_null(), "queue drained empty");

        unsafe { supplier_unregister_and_free(q, r, w) };
    }

    // A register for a DIFFERENT queue fails while one is active (the
    // "only one custom-supplier registry per process" rule, enforced Perl-side
    // as an Argument). Re-registering the SAME queue succeeds (multiple workers
    // on one runtime share the registry — their suppliers accumulate).
    #[test]
    fn t_tuner_second_register_rules() {
        let _guard = SUPPLIER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(unsafe { temporalio_perl_bridge_supplier_register(q) });

        // Same queue: idempotent success.
        assert!(
            unsafe { temporalio_perl_bridge_supplier_register(q) },
            "re-registering the same queue succeeds"
        );

        // Different queue: fails while the first is active.
        let (r2, w2) = nonblocking_pipe();
        let q2 = temporalio_perl_bridge_queue_new(w2);
        assert!(
            !unsafe { temporalio_perl_bridge_supplier_register(q2) },
            "a second runtime's queue cannot claim the active registry"
        );
        unsafe { temporalio_perl_bridge_queue_free(q2) };
        unsafe { libc::close(r2) };
        unsafe { libc::close(w2) };

        unsafe { supplier_unregister_and_free(q, r, w) };
    }

    // complete_reserve with no bound completion fn is a no-op (false); binding a
    // test fn routes the completion_ctx + permit through.
    #[test]
    fn t_tuner_complete_reserve_routes_through_bound_fn() {
        let _guard = SUPPLIER_TEST_LOCK.lock().unwrap();
        let (r, w) = nonblocking_pipe();
        let q = temporalio_perl_bridge_queue_new(w);
        assert!(unsafe { temporalio_perl_bridge_supplier_register(q) });

        // Unbound: no-op false.
        temporalio_perl_bridge_supplier_set_complete_reserve(ptr::null_mut());
        assert!(
            !unsafe {
                temporalio_perl_bridge_supplier_complete_reserve(
                    0x1234 as *const c_void,
                    7,
                )
            },
            "complete_reserve is a no-op without a bound fn"
        );

        // Bind a recording stub and confirm it receives the ctx + permit.
        static LAST_CTX: AtomicUsize = AtomicUsize::new(0);
        static LAST_PERMIT: AtomicUsize = AtomicUsize::new(0);
        unsafe extern "C" fn stub(ctx: *const c_void, permit: usize) -> bool {
            LAST_CTX.store(ctx as usize, Ordering::Release);
            LAST_PERMIT.store(permit, Ordering::Release);
            true
        }
        temporalio_perl_bridge_supplier_set_complete_reserve(stub as *mut c_void);
        let ok = unsafe {
            temporalio_perl_bridge_supplier_complete_reserve(0xABCD as *const c_void, 42)
        };
        assert!(ok, "bound complete_reserve returns the stub's true");
        assert_eq!(LAST_CTX.load(Ordering::Acquire), 0xABCD);
        assert_eq!(LAST_PERMIT.load(Ordering::Acquire), 42);

        temporalio_perl_bridge_supplier_set_complete_reserve(ptr::null_mut());
        unsafe { supplier_unregister_and_free(q, r, w) };
    }
}
