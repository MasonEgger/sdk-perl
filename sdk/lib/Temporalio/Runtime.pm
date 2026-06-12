# ABOUTME: Lifecycle wrapper around TemporalCoreRuntime (spec section 4.2):
# ABOUTME: owns telemetry options, the shim callback queue, and the wakeup fd.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use FFI::Platypus::Buffer ();
use IO::Async::Loop ();
use IO::Async::Handle ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Runtime ();
use Temporalio::Runtime::TelemetryConfig ();

class Temporalio::Runtime {
    field $telemetry                 :param = undef;
    field $worker_heartbeat_interval :param = 60;      # seconds
    field $loop                      :param = undef;   # IO::Async::Loop

    field $core_ptr;       # TemporalCoreRuntime*
    field $queue_ptr;      # TemporalioPerlBridgeQueue*
    field $callback;       # Temporalio::Core::Callback (owns the wakeup fd)
    field $watch_handle;   # IO::Async::Handle registered on $loop
    field $is_shutdown = 0;

    # The lazily-created process default (spec section 4.2). Shutdown of the
    # default clears it, so a later ->default constructs a fresh one.
    our $_DEFAULT;

    ADJUST {
        $telemetry //= Temporalio::Runtime::TelemetryConfig->new;

        # Build the TemporalCoreRuntimeOptions record tree. @keep pins every
        # nested record and backing buffer until runtime_new returns (the
        # bridge copies what it needs during the call).
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

        # Wakeup fd (eventfd vs pipe is hidden inside the Callback stub) and
        # the shim completion queue that signals it.
        $callback  = Temporalio::Core::Callback->new;
        $queue_ptr = Temporalio::Core::FFI::queue_new($callback->signal_fd);

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

    method shutdown () {
        return if $is_shutdown;    # step 6: idempotent

        # Spec section 4.2 shutdown sequence:
        # 1. Unregister the wakeup fd from the loop.
        $loop->remove($watch_handle) if $watch_handle;
        $watch_handle = undef;
        # 2. Free the shim callback queue (drops undrained entries).
        Temporalio::Core::FFI::queue_free($queue_ptr) if defined $queue_ptr;
        $queue_ptr = undef;
        # 3. Free the core runtime (flushes telemetry on drop).
        Temporalio::Core::FFI::runtime_free($core_ptr) if defined $core_ptr;
        $core_ptr = undef;
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

C<shutdown> unregisters the wakeup fd, frees the queue, frees the core
runtime, clears the process default if applicable, and flags the instance:
subsequent operations raise C<"Runtime is shut down">. It is idempotent.
C<DESTROY> shuts down with a warning - call C<shutdown> explicitly.

=head1 METHODS

=head2 core_ptr / queue_ptr / callback / read_handle

Internal accessors for the C runtime pointer, the shim queue pointer, the
owning L<Temporalio::Core::Callback> instance, and the wakeup fd read end.
All raise L<Temporalio::Exception::Runtime> with C<"Runtime is shut down">
after C<shutdown>.

=cut
