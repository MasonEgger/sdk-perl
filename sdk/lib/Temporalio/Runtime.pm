# ABOUTME: Lifecycle wrapper around TemporalCoreRuntime (spec section 4.2):
# ABOUTME: owns telemetry options, the shim callback queue, and the wakeup fd.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Time::HiRes ();
use FFI::Platypus::Buffer ();
use IO::Async::Loop ();
use IO::Async::Handle ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Runtime ();
use Temporalio::Runtime::LogForwardingConfig ();
use Temporalio::Runtime::MetricMeter ();
use Temporalio::Runtime::TelemetryConfig ();

# Upper bound (seconds) on the shutdown drain barrier: how long shutdown
# keeps draining the completion queue waiting for outstanding async bridge
# calls to deliver before failing whatever is still pending (findings L1 and
# L18; spec R1 + R21). Package variable so tests (and unusual embedders) can
# shrink or stretch the window.
our $SHUTDOWN_DRAIN_TIMEOUT = 2;

class Temporalio::Runtime {
    field $telemetry                 :param = undef;
    field $worker_heartbeat_interval :param = 60;      # seconds
    field $loop                      :param = undef;   # IO::Async::Loop

    field $core_ptr;       # TemporalCoreRuntime*
    field $queue_ptr;      # TemporalioPerlBridgeQueue*
    field $callback;       # Temporalio::Core::Callback (owns the wakeup fd)
    field $watch_handle;   # IO::Async::Handle registered on $loop
    field $forwards_logs = 0;   # true if this runtime owns the log-forward registry
    field $custom_meter = 0;    # true if this runtime owns the meter registry
    field $telemetry_keep;      # records core retains by pointer past runtime_new
    field $is_shutdown = 0;

    # The lazily-built user-facing metric meter (spec R83) and its FFI
    # backend. The meter is the noop meter when core has no metrics exporter
    # configured (metric_meter_new returned NULL — sdk-python runtime.py:150).
    field $metric_meter;
    field $metric_meter_backend;

    # The lazily-created process default (spec section 4.2). Shutdown of the
    # default clears it, so a later ->default constructs a fresh one.
    our $_DEFAULT;

    ADJUST {
        $telemetry //= Temporalio::Runtime::TelemetryConfig->new;

        # Log forwarding (spec section 28.1) is process-global: only one
        # runtime may forward at a time (per-id routing deferred). Detect the
        # config and refuse a second forwarder up front, before building the
        # core runtime, so construction fails cleanly.
        my $forwarding = $telemetry->logging
            ? $telemetry->logging->forward_to
            : undef;
        if (defined $forwarding
            && defined Temporalio::Runtime::LogForwardingConfig->active) {
            Temporalio::Exception::Argument->throw(
                message => 'log forwarding is already active on another runtime'
                         . ' (only one runtime may forward core logs at a time)',
            );
        }

        # Custom metric meter (spec section 28.2) is likewise process-global:
        # only one runtime may carry a custom meter (the C bridge's "only one
        # of opentelemetry/prometheus/custom_meter"). Refuse a second up front.
        my $meter = $telemetry->custom_meter;
        if (defined $meter
            && defined Temporalio::Runtime::MetricMeter->active) {
            Temporalio::Exception::Argument->throw(
                message => 'a custom metric meter is already active on another'
                         . ' runtime (only one runtime may carry one at a time)',
            );
        }

        # Build the TemporalCoreRuntimeOptions record tree. @keep pins every
        # nested record and backing buffer until runtime_new returns (the
        # bridge copies what it needs during the call). EXCEPTION: a custom
        # metric meter's TemporalCoreCustomMetricMeter struct is RETAINED by
        # core for the runtime's lifetime (header: "freed by a callback within
        # itself"), so when a meter is configured @keep must outlive
        # runtime_new — it is moved into $telemetry_keep below.
        my @keep;
        my $telemetry_ptr = Temporalio::Core::FFI::keep_record(
            \@keep, $telemetry->to_ffi(\@keep));
        my $options = Temporalio::Core::FFI::RuntimeOptions->new(
            telemetry                        => $telemetry_ptr,
            worker_heartbeat_interval_millis => defined $worker_heartbeat_interval
                ? int($worker_heartbeat_interval * 1000)
                : 0,    # 0 = use the core default (verified in P0.6)
        );

        my $result   = Temporalio::Core::FFI::runtime_new($options);
        my $fail_ptr = scalar $result->fail;
        $core_ptr    = scalar $result->runtime;
        if (defined $fail_ptr) {
            # runtime_new returns a throwaway runtime alongside the failure
            # so the failure byte array can be freed (sdk-core-c-bridge
            # runtime.rs); read the message, then free both.
            my $view = Temporalio::Core::FFI::ffi()->cast(
                'opaque' => 'record(Temporalio::Core::FFI::ByteArray)*',
                $fail_ptr);
            my $message = FFI::Platypus::Buffer::buffer_to_scalar(
                $view->data, $view->size);
            Temporalio::Core::FFI::byte_array_free($core_ptr, $fail_ptr);
            Temporalio::Core::FFI::runtime_free($core_ptr);
            $core_ptr = undef;
            Temporalio::Exception::Runtime->throw(message => $message);
        }

        # Core retains the custom-meter struct by pointer for the runtime's
        # lifetime, so keep @keep (which pins the TemporalCoreCustomMetricMeter
        # record) alive until shutdown when a meter is configured. Without this
        # the meter struct is freed right after runtime_new and core later
        # dereferences a dangling pointer (a nondeterministic crash).
        $telemetry_keep = \@keep if defined $meter;

        # Wakeup fd (eventfd vs pipe is hidden inside the Callback stub) and
        # the shim completion queue that signals it.
        $callback  = Temporalio::Core::Callback->new;
        $queue_ptr = Temporalio::Core::FFI::queue_new($callback->signal_fd);

        # If forwarding is configured, claim the process-global shim registry
        # for this queue and install the active LogForwardingConfig the drain
        # dispatches kind-7 entries to. The shim's compare-and-set guards
        # against a TOCTOU race past the Perl-side pre-check above.
        if (defined $forwarding) {
            my @accessors = Temporalio::Core::FFI::forwarded_log_accessor_ptrs();
            unless (Temporalio::Core::FFI::forwarding_register($queue_ptr, @accessors)) {
                Temporalio::Core::FFI::queue_free($queue_ptr);
                $queue_ptr = undef;
                $callback->close;
                $callback = undef;
                Temporalio::Core::FFI::runtime_free($core_ptr);
                $core_ptr = undef;
                Temporalio::Exception::Argument->throw(
                    message => 'log forwarding is already active on another'
                             . ' runtime (only one runtime may forward core'
                             . ' logs at a time)',
                );
            }
            Temporalio::Runtime::LogForwardingConfig->_set_active($forwarding);
            $forwards_logs = 1;
        }

        # If a custom meter is configured, claim the process-global meter
        # registry for this queue (spec section 28.2). The shim allocates handle
        # ids and parks create/free requests the drain runs; record_* aggregate
        # in pure Rust. No blocking, no off-main-thread Perl, no nested FFI
        # re-entry (the spike resolution).
        if (defined $meter) {
            unless (Temporalio::Core::FFI::meter_register($queue_ptr)) {
                if ($forwards_logs) {
                    Temporalio::Core::FFI::forwarding_unregister($queue_ptr);
                    Temporalio::Runtime::LogForwardingConfig->_clear_active;
                    $forwards_logs = 0;
                }
                Temporalio::Core::FFI::queue_free($queue_ptr);
                $queue_ptr = undef;
                $callback->close;
                $callback = undef;
                Temporalio::Core::FFI::runtime_free($core_ptr);
                $core_ptr = undef;
                Temporalio::Exception::Argument->throw(
                    message => 'a custom metric meter is already active on'
                             . ' another runtime (only one runtime may carry'
                             . ' one at a time)',
                );
            }
            Temporalio::Runtime::MetricMeter->_set_active($meter);
            $custom_meter = 1;
        }

        # Register the read end with the loop: when the shim signals the fd,
        # drain the completion queue and resolve pending Futures (spec
        # section 4.5). $weak_self keeps the closure from holding the
        # runtime alive (loop -> handle -> closure -> self would otherwise
        # cycle and DESTROY could never run); $callback is the captured
        # field, undef once shutdown has torn it down.
        $loop //= IO::Async::Loop->new;
        my $weak_self = $self;
        Scalar::Util::weaken($weak_self);
        $watch_handle = IO::Async::Handle->new(
            read_handle   => $callback->read_handle,
            on_read_ready => sub {
                $callback->drain($weak_self)
                    if defined $weak_self && defined $callback;
            },
        );
        $loop->add($watch_handle);
    }

    sub default ($class) {
        $_DEFAULT //= $class->new;
        return $_DEFAULT;
    }

    sub set_default ($class, $runtime, %options) {
        my $error_if_already_set = $options{error_if_already_set} // 1;
        if (defined $_DEFAULT) {
            Temporalio::Exception::Runtime->throw(
                message => 'Default runtime already set')
                if $error_if_already_set;
            $_DEFAULT->shutdown;    # also clears $_DEFAULT
        }
        $_DEFAULT = $runtime;
        return $runtime;
    }

    method _assert_open () {
        Temporalio::Exception::Runtime->throw(message => 'Runtime is shut down')
            if $is_shutdown;
        return;
    }

    method core_ptr ()    { $self->_assert_open; $core_ptr }
    method queue_ptr ()   { $self->_assert_open; $queue_ptr }
    method callback ()    { $self->_assert_open; $callback }
    method read_handle () { $self->_assert_open; $callback->read_handle }
    method loop ()        { $loop }
    method is_shutdown () { $is_shutdown }

    # metric_meter() -> the user-facing Temporalio::Runtime::MetricMeter::Meter
    # for this runtime (spec R83), created on first use over the core meter
    # surface; the shared noop meter when no metrics exporter is configured
    # (MUST-match sdk-python Runtime.metric_meter, runtime.py:150-161). The
    # worker threads this meter to the workflow, activity, and Nexus contexts.
    method metric_meter () {
        $self->_assert_open;
        return $metric_meter //= do {
            my $meter_ptr = Temporalio::Core::FFI::metric_meter_new($core_ptr);
            if (defined $meter_ptr) {
                $metric_meter_backend =
                    Temporalio::Runtime::MetricMeter::CoreBackend->new(
                        meter_ptr => $meter_ptr);
                Temporalio::Runtime::MetricMeter::Meter->new(
                    backend => $metric_meter_backend);
            }
            else {
                Temporalio::Runtime::MetricMeter::Meter->noop;
            }
        };
    }

    method shutdown () {
        return if $is_shutdown;    # step 6: idempotent

        # Spec section 4.2 shutdown sequence:
        # 1. Unregister the wakeup fd from the loop.
        $loop->remove($watch_handle) if $watch_handle;
        $watch_handle = undef;
        # 1b. Release the log-forward registry (spec section 28.1) before the
        # queue is freed, so the shim stops routing forwarded logs to it, then
        # clear the active LogForwardingConfig the drain dispatches to.
        if ($forwards_logs) {
            Temporalio::Core::FFI::forwarding_unregister($queue_ptr)
                if defined $queue_ptr;
            Temporalio::Runtime::LogForwardingConfig->_clear_active;
            $forwards_logs = 0;
        }
        # 1c. Release the custom-meter registry (spec section 28.2) before the
        # queue is freed, so the shim stops routing meter callbacks to it, then
        # clear the active meter and drop the reentrant closure. The core
        # runtime is freed below; no callback can fire after that.
        if ($custom_meter) {
            Temporalio::Core::FFI::meter_unregister($queue_ptr)
                if defined $queue_ptr;
            Temporalio::Runtime::MetricMeter->_clear_active;
            $custom_meter = 0;
        }
        # 1d. Release the custom slot-supplier registry (spec §29.2) before the
        # queue is freed: stop the shim routing supplier callbacks to it, free
        # every leaked callbacks struct, and clear the active impl map. A no-op
        # unless this runtime's queue owns the registry (a worker on this
        # runtime claimed it). Safe here because the core runtime is freed below
        # and no supplier callback can fire afterward.
        if (defined $queue_ptr) {
            Temporalio::Core::FFI::supplier_unregister($queue_ptr);
            require Temporalio::Worker::SlotSupplierRegistry;
            Temporalio::Worker::SlotSupplierRegistry->_clear_active;
        }
        # 1e. Close the user-facing metric-meter backend (spec R83) BEFORE the
        # core runtime is freed: frees every owned attribute set, metric, and
        # the core meter while their runtime is still alive. Meters and
        # instruments still held by user code become safe no-ops.
        if (defined $metric_meter_backend) {
            $metric_meter_backend->close;
            $metric_meter_backend = undef;
        }
        $metric_meter = undef;
        # 2. Ordered completion-channel teardown (findings L1 and L18; spec
        # R1 + R21): barrier -> fail-pending -> queue-free, centralized in
        # one helper so every shutdown path sequences it identically.
        $self->_settle_callbacks_and_free_queue;
        # 3. Free the core runtime (flushes telemetry on drop, and invokes the
        # custom meter's meter_free callback if one was configured).
        Temporalio::Core::FFI::runtime_free($core_ptr) if defined $core_ptr;
        $core_ptr = undef;
        # Now core is gone and can no longer dereference the retained meter
        # struct: release the kept records.
        $telemetry_keep = undef;
        # The queue borrows the wakeup fd and never closes it; close the
        # Perl-owned ends now that nothing can signal.
        $callback->close if defined $callback;
        $callback = undef;
        # 4. Clear the process default if this runtime was it.
        $_DEFAULT = undef
            if defined $_DEFAULT
            && Scalar::Util::refaddr($_DEFAULT) == Scalar::Util::refaddr($self);
        # 5. Flag: subsequent operations raise "Runtime is shut down".
        $is_shutdown = 1;
        return;
    }

    # The one ordered shutdown sequence for the completion channel (findings
    # L1 and L18; spec R1 + R21). Steps, in a fixed order every shutdown
    # path shares:
    #
    # (a) BARRIER (L1/R1): while async bridge calls are outstanding, keep
    #     draining the completion queue on the main thread so in-flight
    #     completions land and settle their futures with real results. The
    #     shim trampolines (ext:206-227 single-shot completion, ext:368-392
    #     forwarded logs) push into this queue from Tokio threads, and
    #     queue_free's contract (ext:1684-1689) requires no further pushes;
    #     freeing without this barrier (the old Runtime.pm:252-253) raced
    #     them. Bounded by $SHUTDOWN_DRAIN_TIMEOUT so a callback that will
    #     never complete (for example an abandoned poll) cannot hang
    #     shutdown.
    # (b) FAIL-PENDING (L18/R21): settle every future still registered in
    #     Core/Callback.pm's $pending with a typed shutdown error, so code
    #     awaiting across shutdown gets a prompt, catchable failure instead
    #     of hanging forever.
    # (c) FREE: only after (a) and (b) may the queue be freed.
    method _settle_callbacks_and_free_queue () {
        if (defined $callback && defined $queue_ptr) {
            my $deadline = Time::HiRes::time() + $SHUTDOWN_DRAIN_TIMEOUT;
            while ($callback->outstanding_count) {
                $callback->drain($self);
                last unless $callback->outstanding_count;
                last if Time::HiRes::time() >= $deadline;
                Time::HiRes::sleep(0.01);
            }
            if (my $count = $callback->outstanding_count) {
                $callback->fail_all_pending(
                    Temporalio::Exception::Runtime->new(
                        message => 'Runtime shut down with '
                                 . "$count callback(s) still pending"));
            }
        }
        Temporalio::Core::FFI::queue_free($queue_ptr) if defined $queue_ptr;
        $queue_ptr = undef;
        return;
    }

    method DESTROY {
        # During global destruction field teardown order is undefined and
        # the process is exiting anyway; skip (same guard as ByteArray).
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        return if $is_shutdown;
        warn 'Temporalio::Runtime: runtime reclaimed without shutdown;'
           . " shutting down in DESTROY (call ->shutdown explicitly)\n";
        $self->shutdown;
    }
}

1;

__END__

=head1 NAME

Temporalio::Runtime - lifecycle wrapper around the Temporal core runtime

=head1 SYNOPSIS

    use Temporalio::Runtime;

    my $rt = Temporalio::Runtime->new(
        telemetry                 => Temporalio::Runtime::TelemetryConfig->new,
        worker_heartbeat_interval => 60,    # seconds; default 60
    );

    my $default = Temporalio::Runtime->default;    # lazy create
    Temporalio::Runtime->set_default($rt, error_if_already_set => 1);

    $rt->shutdown;    # idempotent; flushes telemetry; frees C runtime

=head1 DESCRIPTION

Wraps a C<TemporalCoreRuntime> (spec section 4.2). Construction builds the
C-side C<TemporalCoreRuntimeOptions> from the telemetry config, calls
C<temporal_core_runtime_new>, and raises L<Temporalio::Exception::Runtime>
with the bridge message if construction fails. Each runtime owns one
C<temporalio-perl-bridge> callback queue plus a wakeup fd (owned by a
L<Temporalio::Core::Callback>, which hides the eventfd-vs-pipe choice)
whose read end is registered with an L<IO::Async::Loop> (caller-provided
via C<loop>, or the process loop). When the shim signals the fd, the
watcher runs the callback object's drain loop, which resolves the Futures
issued by C<< Temporalio::Core::Callback->issue_async >> (spec section 4.5).

C<default> lazily creates the process default runtime; C<set_default>
raises C<"Default runtime already set"> unless called with
C<< error_if_already_set => 0 >>, which shuts down and replaces the
previous default.

C<shutdown> unregisters the wakeup fd, then tears the completion channel
down in a fixed order (findings L1 and L18): first a drain barrier keeps
popping the completion queue so outstanding async bridge calls can deliver
and settle their Futures with real results (bounded by
C<$Temporalio::Runtime::SHUTDOWN_DRAIN_TIMEOUT>, default 2 seconds), then
every Future still pending fails with a typed
L<Temporalio::Exception::Runtime> shutdown error so no awaiter hangs, and
only then is the queue freed. It then frees the core runtime, clears the
process default if applicable, and flags the instance: subsequent
operations raise C<"Runtime is shut down">. It is idempotent. C<DESTROY>
shuts down with a warning - call C<shutdown> explicitly.

=head1 METHODS

=head2 core_ptr / queue_ptr / callback / read_handle

Internal accessors for the C runtime pointer, the shim queue pointer, the
owning L<Temporalio::Core::Callback> instance, and the wakeup fd read end.
All raise L<Temporalio::Exception::Runtime> with C<"Runtime is shut down">
after C<shutdown>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Runtime->new(
        telemetry => ...,
        worker_heartbeat_interval => ...,
        loop => ...,
    );

Constructs a Temporalio::Runtime. Named parameters:

=over 4

=item C<telemetry>

(optional, default C<undef>)

=item C<worker_heartbeat_interval>

(optional, default C<60>)

=item C<loop>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 default

Class method returning the process-wide default runtime, creating it on first use.

=head2 is_shutdown

Accessor returning the C<is_shutdown> value.

=head2 metric_meter

The user-facing L<Temporalio::Runtime::MetricMeter::Meter> for this runtime
(spec R83), lazily created over the core meter surface
(C<temporal_core_metric_meter_new>). When no metrics exporter is configured
this is the shared noop meter (recording is a safe no-op), matching
sdk-python's C<Runtime.metric_meter>. The worker threads this meter to the
workflow, activity, and Nexus contexts; C<shutdown> closes the backing core
meter, after which held meters and instruments become safe no-ops. Raises
C<"Runtime is shut down"> when called after C<shutdown>.

=head2 loop

Accessor returning the C<loop> value.

=head2 set_default

Class method installing a runtime as the process-wide default.

=head2 shutdown

Shuts the runtime down, stopping its IO::Async loop and freeing the sdk-core runtime.
The completion channel is torn down in order: drain barrier, fail every
pending callback Future with a typed shutdown error, free the queue.

=cut
