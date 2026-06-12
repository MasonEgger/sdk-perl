// ABOUTME: Rust callback shim for the Temporalio Perl SDK (spec section 3).
// ABOUTME: Trampolines enqueue completions and signal an fd; never touch Perl.

use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::{AtomicI32, Ordering};

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

/// `kind` discriminator values, 1..6 in spec section 3 trampoline order.
pub const TEMPORALIO_PERL_BRIDGE_KIND_WORKER_POLL: u8 = 1;
pub const TEMPORALIO_PERL_BRIDGE_KIND_WORKER: u8 = 2;
pub const TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_CONNECT: u8 = 3;
pub const TEMPORALIO_PERL_BRIDGE_KIND_CLIENT_RPC_CALL: u8 = 4;
pub const TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_START: u8 = 5;
pub const TEMPORALIO_PERL_BRIDGE_KIND_EPHEMERAL_SERVER_SHUTDOWN: u8 = 6;

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
    /// RPC call extras (fail_ba carries the failure_message).
    pub rpc_status_code: u32,
    pub rpc_failure_details: *const TemporalCoreByteArray,
    /// Ephemeral server start target string.
    pub ephemeral_target: *const TemporalCoreByteArray,
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
        }
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
        ] {
            assert!(header.contains(sym), "header missing {sym}");
        }
    }
}
