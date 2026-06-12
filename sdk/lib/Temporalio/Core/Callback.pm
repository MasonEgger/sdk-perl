# ABOUTME: Bridges FFI completion entries to Perl Futures (spec section 4.5):
# ABOUTME: owns the wakeup fd, issues async bridge calls, drains + dispatches.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use FFI::Platypus::Buffer ();
use Temporalio::Core::ByteArray ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Bridge ();
use Temporalio::Exception::Runtime ();

# Process-wide monotonic 64-bit callback id (spec section 4.5).
my $NEXT_CALLBACK_ID = 1;

# Entries popped per queue_drain call; the drain loop calls until 0.
my $DRAIN_CAP = 256;

# sizeof(TemporalioPerlBridgeEntry): the drain buffer's per-slot stride.
my $ENTRY_SIZE = Temporalio::Core::FFI::ffi()
    ->sizeof('record(Temporalio::Core::FFI::CallbackEntry)');

# issue_async kind name -> shim trampoline pointer, cached at module load.
my %TRAMPOLINE_PTR = (
    worker_poll     => Temporalio::Core::FFI::worker_poll_callback_ptr(),
    worker          => Temporalio::Core::FFI::worker_callback_ptr(),
    connect         => Temporalio::Core::FFI::client_connect_callback_ptr(),
    rpc             => Temporalio::Core::FFI::client_rpc_call_callback_ptr(),
    server_start    => Temporalio::Core::FFI::ephemeral_server_start_callback_ptr(),
    server_shutdown => Temporalio::Core::FFI::ephemeral_server_shutdown_callback_ptr(),
);

class Temporalio::Core::Callback {
    # Copy a *const TemporalCoreByteArray's contents into a Perl scalar and
    # free it through the bridge. Returns undef for a null pointer.
    sub _consume_byte_array ($runtime, $ba_ptr) {
        return undef unless defined $ba_ptr;
        my $byte_array = Temporalio::Core::ByteArray->wrap($ba_ptr, $runtime);
        my $bytes      = $byte_array->bytes;
        $byte_array->free;
        return $bytes;
    }

    sub _bridge_failure ($message) {
        return Temporalio::Exception::Bridge->new(message => $message);
    }

    # Per-kind result builders keyed on entry.kind (1..6 in trampoline
    # order). Each consumes (and frees) the entry's byte arrays and returns
    # (done => $value) or (fail => $exception) for the pending Future.
    my %COMPLETE_FOR_KIND = (
        # worker_poll: null/null is the shutdown sentinel -> done(undef).
        1 => sub ($runtime, $entry) {
            my $fail    = _consume_byte_array($runtime, scalar $entry->fail_ba);
            my $success = _consume_byte_array($runtime, scalar $entry->success_ba);
            return (fail => _bridge_failure($fail)) if defined $fail;
            return (done => $success);
        },
        # worker (completion/finalize): fail-or-nothing.
        2 => sub ($runtime, $entry) {
            my $fail = _consume_byte_array($runtime, scalar $entry->fail_ba);
            return (fail => _bridge_failure($fail)) if defined $fail;
            return (done => undef);
        },
        # connect: a TemporalCoreConnection pointer or a failure.
        3 => sub ($runtime, $entry) {
            my $fail = _consume_byte_array($runtime, scalar $entry->fail_ba);
            return (fail => _bridge_failure($fail)) if defined $fail;
            return (done => scalar $entry->success_handle);
        },
        # rpc: always resolves done with the decoded completion fields;
        # mapping status_code/failure onto the exception hierarchy is the
        # client layer's job (spec section 7.5), which owns the gRPC table.
        4 => sub ($runtime, $entry) {
            return (done => {
                success         => _consume_byte_array($runtime, scalar $entry->success_ba),
                status_code     => scalar $entry->rpc_status_code,
                failure_message => _consume_byte_array($runtime, scalar $entry->fail_ba),
                failure_details => _consume_byte_array($runtime, scalar $entry->rpc_failure_details),
            });
        },
        # server_start: an ephemeral server handle plus its host:port target.
        5 => sub ($runtime, $entry) {
            my $fail   = _consume_byte_array($runtime, scalar $entry->fail_ba);
            my $target = _consume_byte_array($runtime, scalar $entry->ephemeral_target);
            return (fail => _bridge_failure($fail)) if defined $fail;
            return (done => {
                handle => scalar $entry->success_handle,
                target => $target,
            });
        },
        # server_shutdown: fail-or-nothing.
        6 => sub ($runtime, $entry) {
            my $fail = _consume_byte_array($runtime, scalar $entry->fail_ba);
            return (fail => _bridge_failure($fail)) if defined $fail;
            return (done => undef);
        },
    );

    field $read_handle;     # what the IO::Async loop watches
    field $write_handle;    # pipe write end (undef when eventfd: one fd)
    field $signal_fd;       # fd number the shim queue writes to
    field $pending = {};    # callback_id => { kind => ..., future => ... }

    # Eventfd on Linux (Linux::FD::Event), nonblocking pipe elsewhere (or if
    # Linux::FD is unavailable). The choice is hidden here: the rest of the
    # SDK only sees an IO::Async-compatible read end plus the signal fd
    # number to hand to temporalio_perl_bridge_queue_new. The queue borrows
    # the fd and never closes it; this object owns both ends (spec section 3).
    ADJUST {
        if ($^O eq 'linux' && eval { require Linux::FD::Event; 1 }) {
            my $event_fd = Linux::FD::Event->new(0, 'non-blocking');
            $read_handle = $event_fd;
            $signal_fd   = fileno($event_fd);
        }
        else {
            pipe($read_handle, $write_handle)
                or Temporalio::Exception::Runtime->throw(
                    message => "could not create wakeup pipe: $!");
            $read_handle->blocking(0);
            $write_handle->blocking(0);
            $signal_fd = fileno($write_handle);
        }
    }

    method read_handle () { $read_handle }
    method signal_fd ()   { $signal_fd }

    # Class method (spec section 4.5 public API): issue an async bridge call
    # on $runtime. Registers a pending Future under a fresh callback id,
    # allocates the shim (queue, id) user_data pair, and calls
    # $invoke->($user_data, $trampoline_ptr); $invoke passes both to the
    # sdk-core-c-bridge async function. The trampoline frees the pair after
    # enqueueing — Perl never frees it.
    sub issue_async ($class, $runtime, $kind, $invoke) {
        my $trampoline = $TRAMPOLINE_PTR{$kind}
            // Temporalio::Exception::Argument->throw(
                message => "unknown callback kind '$kind'");
        return $runtime->callback->_register($runtime, $kind, $trampoline, $invoke);
    }

    method _register ($runtime, $kind, $trampoline, $invoke) {
        my $id     = $NEXT_CALLBACK_ID++;
        my $future = $runtime->loop->new_future;
        $pending->{$id} = { kind => $kind, future => $future };
        my $user_data = Temporalio::Core::FFI::user_data_new(
            $runtime->queue_ptr, $id);
        # If $invoke dies the bridge call never started: drop the pending
        # record and rethrow. (The user_data pair leaks — the shim only
        # frees it from a trampoline — but nothing will ever complete it.)
        my $invoked = eval { $invoke->($user_data, $trampoline); 1 };
        if (!$invoked) {
            delete $pending->{$id};
            die $@;
        }
        return $future;
    }

    # Drain loop (spec section 4.5): runs on the main thread when the
    # runtime's fd watcher reads ready. Pops entries in $DRAIN_CAP chunks
    # until the queue reports empty, dispatching each to its per-kind
    # builder and resolving the pending Future.
    method drain ($runtime) {
        # Pipe mode: the shim holds only the write end, so empty the read
        # end here BEFORE popping entries — a push after this read writes a
        # fresh byte, so no wakeup is lost. Eventfd mode: queue_drain clears
        # the counter itself (same ordering, shim side).
        if (defined $write_handle) {
            1 while sysread($read_handle, my $discard, 4096);
        }

        my $buffer = "\0" x ($ENTRY_SIZE * $DRAIN_CAP);
        my ($buffer_ptr) = FFI::Platypus::Buffer::scalar_to_buffer($buffer);
        my $ffi = Temporalio::Core::FFI::ffi();
        while ((my $count = Temporalio::Core::FFI::queue_drain(
                    $runtime->queue_ptr, $buffer_ptr, $DRAIN_CAP)) > 0) {
            for my $slot (0 .. $count - 1) {
                my $entry = $ffi->cast(
                    'opaque' => 'record(Temporalio::Core::FFI::CallbackEntry)*',
                    $buffer_ptr + $slot * $ENTRY_SIZE);
                $self->_complete($runtime, $entry);
            }
        }
        return;
    }

    method _complete ($runtime, $entry) {
        my $id     = $entry->callback_id;
        my $kind   = $entry->kind;
        my $record = delete $pending->{$id};

        if (!defined $record) {
            # Spec section 4.5 failure mode: would be a bridge bug. Free the
            # byte arrays, warn, drop — never crash the worker loop.
            _consume_byte_array($runtime, scalar $entry->$_)
                for qw(success_ba fail_ba rpc_failure_details ephemeral_target);
            warn "Temporalio::Core::Callback: stale callback id $id"
               . " (kind $kind) dropped\n";
            return;
        }

        my $build = $COMPLETE_FOR_KIND{$kind};
        if (!defined $build) {
            # Unreachable unless the shim grows a kind this code predates.
            _consume_byte_array($runtime, scalar $entry->$_)
                for qw(success_ba fail_ba rpc_failure_details ephemeral_target);
            $record->{future}->fail(
                _bridge_failure("unknown completion kind $kind for callback id $id"));
            return;
        }

        my ($resolution, $value) = $build->($runtime, $entry);
        $resolution eq 'fail'
            ? $record->{future}->fail($value)
            : $record->{future}->done($value);
        return;
    }

    # Close the Perl-owned fd(s). Call only after the shim queue is freed:
    # the queue borrows signal_fd and must never write to a closed fd.
    method close () {
        close $read_handle  if defined $read_handle;
        close $write_handle if defined $write_handle;
        ($read_handle, $write_handle, $signal_fd) = (undef, undef, undef);
        return;
    }
}

1;

__END__

=head1 NAME

Temporalio::Core::Callback - FFI completion to Perl Future bridge

=head1 SYNOPSIS

    use Temporalio::Core::Callback;

    # Issue an async bridge call on a Temporalio::Runtime:
    my $f = Temporalio::Core::Callback->issue_async(
        $runtime,
        'worker_poll',    # worker | connect | rpc | server_start | server_shutdown
        sub ($user_data, $trampoline_ptr) {
            # pass both to the sdk-core-c-bridge async function
        },
    );
    my $result = await $f;

=head1 DESCRIPTION

The bridge between FFI callback completion and Perl-side Future resolution
(spec section 4.5). Each instance owns the wakeup fd that the
C<temporalio-perl-bridge> completion queue signals from Tokio threads: an
eventfd via L<Linux::FD::Event> on Linux (nonblocking), or a nonblocking
C<pipe(2)> pair elsewhere. C<signal_fd> is the fd number passed to
C<temporalio_perl_bridge_queue_new>; C<read_handle> is the IO::Async-watched
read end. The queue borrows the fd and never closes it - call C<close>
after the queue is freed.

C<issue_async> allocates a process-wide monotonic callback id, records a
pending Future for it, pairs the runtime's queue with the id via
C<temporalio_perl_bridge_user_data_new>, and hands the pair plus the cached
trampoline pointer to the invoke coderef. The trampoline (running on a
Tokio thread) enqueues the completion entry, frees the pair, and signals
the fd; the runtime's L<IO::Async> watcher then calls C<drain> on the main
thread.

C<drain> pops entries in chunks of 256 until the queue is empty. Each
entry is dispatched on its C<kind> discriminator: C<worker_poll> resolves
with the raw activation bytes (C<undef> for the null/null shutdown
sentinel) or fails with L<Temporalio::Exception::Bridge>; C<worker> and
C<server_shutdown> resolve with C<undef> or fail; C<connect> resolves with
the connection pointer; C<rpc> resolves with a hashref of
C<success>/C<status_code>/C<failure_message>/C<failure_details> (the
client layer maps failures per spec section 7.5); C<server_start> resolves
with a C<< { handle, target } >> hashref. Byte arrays are freed through
the bridge once consumed. A completion whose callback id has no pending
Future is warned about and dropped, never fatal.

=cut
