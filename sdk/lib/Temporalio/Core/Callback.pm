# ABOUTME: Bridges FFI completion entries to Perl Futures (spec section 4.5):
# ABOUTME: owns the wakeup fd, issues async bridge calls, drains + dispatches.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use FFI::Platypus::Buffer ();
use Temporalio::Core::ByteArray ();
use Temporalio::Core::FFI ();
use Temporalio::Core::Proto ();
use Temporalio::Exception::ActivityNotFound ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Bridge ();
use Temporalio::Exception::Cancelled ();
use Temporalio::Exception::NamespaceNotFound ();
use Temporalio::Exception::QueryRejected ();
use Temporalio::Exception::RpcError ();
use Temporalio::Exception::RpcPermissionDenied ();
use Temporalio::Exception::RpcResourceExhausted ();
use Temporalio::Exception::RpcTimeout ();
use Temporalio::Exception::RpcUnauthenticated ();
use Temporalio::Exception::Runtime ();
use Temporalio::Exception::WorkflowAlreadyStarted ();
use Temporalio::Exception::WorkflowNotFound ();
use Temporalio::Runtime::LogForwardingConfig ();
use Temporalio::Runtime::MetricMeter ();
use Temporalio::Worker::SlotSupplierRegistry ();

# Process-wide monotonic 64-bit callback id (spec section 4.5).
my $NEXT_CALLBACK_ID = 1;

# Entries popped per queue_drain call; the drain loop calls until 0.
my $DRAIN_CAP = 256;

# Aggregated meter records pulled per meter_drain_records call (spec section
# 28.2); the drain loop calls until 0.
my $METER_RECORD_CAP = 256;

# sizeof(TemporalioPerlBridgeMeterRecord): the record-drain buffer's stride.
my $METER_RECORD_SIZE = Temporalio::Core::FFI::ffi()
    ->sizeof('record(Temporalio::Core::FFI::MeterRecord)');

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

    # --- spec section 7.5: RPC error -> exception mapping -------------------

    # gRPC status code -> canonical name, lowercased (MUST-match table;
    # verified against sdk-python service.py RPCStatusCode, lines 418-437).
    my %GRPC_STATUS_NAME = (
        0  => 'ok',
        1  => 'cancelled',
        2  => 'unknown',
        3  => 'invalid_argument',
        4  => 'deadline_exceeded',
        5  => 'not_found',
        6  => 'already_exists',
        7  => 'permission_denied',
        8  => 'resource_exhausted',
        9  => 'failed_precondition',
        10 => 'aborted',
        11 => 'out_of_range',
        12 => 'unimplemented',
        13 => 'internal',
        14 => 'unavailable',
        15 => 'data_loss',
        16 => 'unauthenticated',
    );

    # The non-special-cased rows of the spec section 7.5 lookup table. Codes
    # 5 (NOT_FOUND), 6 (ALREADY_EXISTS), and 9 (FAILED_PRECONDITION) are
    # handled contextually in rpc_error_for; everything else not listed here
    # is the RpcError catch-all.
    my %CLASS_FOR_CODE = (
        1  => 'Temporalio::Exception::Cancelled',
        4  => 'Temporalio::Exception::RpcTimeout',
        7  => 'Temporalio::Exception::RpcPermissionDenied',
        8  => 'Temporalio::Exception::RpcResourceExhausted',
        16 => 'Temporalio::Exception::RpcUnauthenticated',
    );

    # Decode failure_details as a google.rpc.Status when present. The bridge
    # sends an EMPTY (non-null) byte array when tonic carried no
    # grpc-status-details-bin, so empty and absent both mean "no details".
    # Returns undef on garbage - mapping an error must never die.
    sub _decode_grpc_status ($details) {
        return undef unless defined $details && length $details;
        return scalar eval {
            Temporalio::Core::Proto::resolve('google.rpc.Status')
                ->decode($details);
        };
    }

    # Unpack a google.protobuf.Any against an expected full message name
    # (Any.type_url is "<prefix>/<full name>"). Returns undef on a type
    # mismatch or undecodable value.
    sub _unpack_any ($any, $full_name) {
        return undef unless defined $any
            && ($any->type_url // '') =~ m{/\Q$full_name\E\z};
        return scalar eval {
            Temporalio::Core::Proto::resolve($full_name)
                ->decode($any->value // '');
        };
    }

    # rpc_error_for(status_code => ..., message => ..., details => $raw,
    #               rpc => $rpc_name, %context)
    # Builds (does not throw) the exception for a failed RPC completion per
    # the spec section 7.5 MUST-match table. $raw is the raw failure_details
    # byte string (a serialized google.rpc.Status). %context may carry
    # workflow_id / workflow_type for the ALREADY_EXISTS special case.
    sub rpc_error_for (%args) {
        my $code    = $args{status_code} // 0;
        my $message = $args{message} // 'RPC call failed';
        my $rpc     = $args{rpc} // '';
        my $status  = _decode_grpc_status($args{details});

        # 5 NOT_FOUND, special-cased on the operation kind: namespace ops
        # raise NamespaceNotFound, activity ops ActivityNotFound, everything
        # else (the common case) WorkflowNotFound.
        if ($code == 5) {
            my $class = $rpc =~ /Namespace/ ? 'Temporalio::Exception::NamespaceNotFound'
                      : $rpc =~ /Activity/  ? 'Temporalio::Exception::ActivityNotFound'
                      :                       'Temporalio::Exception::WorkflowNotFound';
            return $class->new(message => $message);
        }

        # 6 ALREADY_EXISTS, special-cased on start_workflow: like sdk-python
        # client/_impl.py and sdk-ruby internal/client/implementation.rb,
        # only when details[0] unpacks as the errordetails failure; otherwise
        # fall through to the RpcError catch-all.
        if ($code == 6
            && $rpc =~ /\A(?:SignalWithStart|Start)WorkflowExecution\z/)
        {
            my $failure = _unpack_any(
                $status && $status->details->[0],
                'temporal.api.errordetails.v1.WorkflowExecutionAlreadyStartedFailure',
            );
            if (defined $failure) {
                return Temporalio::Exception::WorkflowAlreadyStarted->new(
                    message       => $message,
                    workflow_id   => $args{workflow_id},
                    workflow_type => $args{workflow_type},
                    run_id        => $failure->run_id,
                );
            }
        }

        # 9 FAILED_PRECONDITION, special-cased on query rejection.
        if ($code == 9 && $rpc eq 'QueryWorkflow') {
            return Temporalio::Exception::QueryRejected->new(
                message => $message);
        }

        my $class = $CLASS_FOR_CODE{$code} // 'Temporalio::Exception::RpcError';
        return $class->new(message => $message)
            unless $class->isa('Temporalio::Exception::RpcError');
        return $class->new(
            message     => $message,
            status_code => $code,
            # Code 0 with a failure message is a non-gRPC failure (client.rs:
            # "Status code may still be 0 with a failure message").
            status_name => $code ? $GRPC_STATUS_NAME{$code} : undef,
            details     => $status,
        );
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

    # Outstanding async bridge calls: futures registered by issue_async that
    # no drain has settled yet. The runtime shutdown barrier (findings L1 and
    # L18) polls this to decide whether in-flight completions may still push
    # into the completion queue.
    method outstanding_count () { scalar keys %$pending }

    # Settle every still-pending future with $error (finding L18 / spec R21):
    # runtime shutdown tears down the delivery mechanism, so any future left
    # in $pending would otherwise hang its awaiter forever. Clears the
    # registry; returns the number of futures failed.
    method fail_all_pending ($error) {
        my @records = values %$pending;
        %$pending = ();
        my $failed = 0;
        for my $record (@records) {
            my $future = $record->{future};
            next unless defined $future && !$future->is_ready;
            $future->fail($error);
            $failed++;
        }
        return $failed;
    }

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
                my $entry_ptr = $buffer_ptr + $slot * $ENTRY_SIZE;
                my $entry = $ffi->cast(
                    'opaque' => 'record(Temporalio::Core::FFI::CallbackEntry)*',
                    $entry_ptr);
                $self->_complete($runtime, $entry, $entry_ptr);
            }
        }

        # Service the custom-meter channels (spec section 28.2) on the same
        # main-thread wakeup: first the marshalled create/free requests parked
        # by off-core-thread callbacks (run the Perl method, post the result so
        # the blocked core thread proceeds), then the aggregated record buckets.
        if (defined Temporalio::Runtime::MetricMeter->active) {
            _service_meter_requests();
            _drain_meter_records();
        }

        # Service custom slot-supplier callbacks (spec §29.2) on the same
        # main-thread wakeup: the shim parked each reserve/try_reserve/mark_used/
        # release/free off a core thread; run the Perl impl method here and
        # complete any async reservation. Same never-touch-Perl-off-core-thread
        # discipline as the meter.
        if (Temporalio::Worker::SlotSupplierRegistry->active) {
            Temporalio::Worker::SlotSupplierRegistry->_service_requests;
        }
        return;
    }

    # Run every parked meter create/free request (spec section 28.2). The shim
    # allocated each handle id and returned it to core synchronously; the
    # request carries the id plus the create payload. meter_next_request pops
    # the next request (an 8-byte tag slot, the request pointer as the return),
    # the drain runs the Perl method (binding the id), then meter_free_request
    # frees the request box. The shim never blocks waiting on this.
    sub _service_meter_requests () {
        my $ffi = Temporalio::Core::FFI::ffi();
        # A 1-byte slot the shim writes the request tag into.
        my $tag_slot = "\0";
        my ($tag_ptr) = FFI::Platypus::Buffer::scalar_to_buffer($tag_slot);
        while (1) {
            my $request_ptr =
                Temporalio::Core::FFI::meter_next_request($tag_ptr);
            last unless defined $request_ptr && $request_ptr;
            my $tag = unpack 'C', $tag_slot;
            Temporalio::Runtime::MetricMeter->_run_request($tag, $request_ptr);
            Temporalio::Core::FFI::meter_free_request($request_ptr);
        }
        return;
    }

    # Pull the shim's aggregated record buckets (spec section 28.2) and apply
    # each to the active meter. The shim sums record_* on core threads; this
    # drains snapshots on the main thread, never dropping a record.
    sub _drain_meter_records () {
        my $ffi    = Temporalio::Core::FFI::ffi();
        my $buffer = "\0" x ($METER_RECORD_SIZE * $METER_RECORD_CAP);
        my ($buffer_ptr) = FFI::Platypus::Buffer::scalar_to_buffer($buffer);
        while ((my $count = Temporalio::Core::FFI::meter_drain_records(
                    $buffer_ptr, $METER_RECORD_CAP)) > 0) {
            for my $slot (0 .. $count - 1) {
                my $record_ptr = $buffer_ptr + $slot * $METER_RECORD_SIZE;
                my $record = $ffi->cast(
                    'opaque' => 'record(Temporalio::Core::FFI::MeterRecord)*',
                    $record_ptr);
                Temporalio::Runtime::MetricMeter->_apply_record({
                    metric_id     => scalar $record->metric_id,
                    attributes_id => scalar $record->attributes_id,
                    record_kind   => scalar $record->record_kind,
                    value         => scalar $record->value,
                    count         => scalar $record->count,
                });
            }
        }
        return;
    }

    # Read a shim-owned NUL-terminated C string from an opaque pointer field;
    # undef pointer -> empty string (the shim never emits a null log buffer).
    sub _read_cstring ($ptr) {
        return '' unless defined $ptr;
        return Temporalio::Core::FFI::ffi()->cast('opaque' => 'string', $ptr);
    }

    # Kind-7 forwarded-log builder (spec section 28.1). Unlike kinds 1..6,
    # the entry has no callback_id and no pending Future: the shim routes
    # every forwarded log to the one process-global registry. Copy the
    # shim-owned target/message/fields strings into Perl scalars, free the
    # shim buffers, build %args, and hand the log to the active
    # LogForwardingConfig. A torn-down registry (no active config) drops the
    # log after freeing the buffers. $entry_ptr is the entry's address in the
    # drain buffer (needed to free the buffers in place).
    sub _forward_log ($entry, $entry_ptr) {
        my %args = (
            level        => scalar $entry->rpc_status_code,
            target       => _read_cstring(scalar $entry->log_target),
            message      => _read_cstring(scalar $entry->log_message),
            fields_json  => _read_cstring(scalar $entry->log_fields_json),
            timestamp_ms => scalar $entry->log_timestamp_ms,
        );
        # Free the shim-owned buffers now that the strings are copied out.
        Temporalio::Core::FFI::forwarded_log_free($entry_ptr);

        my $config = Temporalio::Runtime::LogForwardingConfig->active;
        return unless defined $config;    # forwarding torn down: drop
        $config->_on_log(%args);
        return;
    }

    method _complete ($runtime, $entry, $entry_ptr) {
        if ($entry->kind == 7) {
            _forward_log($entry, $entry_ptr);
            return;
        }

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

=encoding utf8

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

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Core::Callback.

=head1 METHODS

=head2 close

Tears down the callback dispatcher and its signal handle.

=head2 drain

Drains the runtime's completion queue, resolving the Futures of any callbacks the shim has signalled.

=head2 fail_all_pending

Settles every still-pending callback Future with the given error and clears
the registry; returns the number failed. Called by the runtime shutdown
sequence (findings L1 and L18) so no awaiter hangs across shutdown.

=head2 issue_async

Issues an async bridge call, registering a callback that the shim trampoline will resolve by pushing onto the runtime queue; returns a L<Future>.

=head2 outstanding_count

Returns the number of async bridge calls whose Futures are still pending.
The runtime shutdown drain barrier polls this before freeing the queue.

=head2 read_handle

Accessor returning the C<read_handle> value.

=head2 rpc_error_for

Maps a bridge failure byte-array into the appropriate L<Temporalio::Exception::RpcError> subclass.

=head2 signal_fd

Accessor returning the C<signal_fd> value.

=cut
