# ABOUTME: Process-wide FFI::Platypus (api => 2) loading the sdk-core C bridge
# ABOUTME: and temporalio-perl-bridge cdylibs and attaching the SDK's C ABI set.
use v5.38;
use warnings;

# Record classes for structs passed by value across the C ABI. Field layouts
# MUST match temporal-sdk-core-c-bridge.h at the pinned sdk-rust tag (see
# plan P0.10 for the marshalling spike that verifies layouts empirically).
# FFI::Platypus::Record does not support nested records, so embedded
# TemporalCoreByteArrayRef members are flattened to (data, size) field pairs.

package Temporalio::Core::FFI::ByteArrayRef {
    use FFI::Platypus::Record;
    record_layout_1(
        opaque => 'data',
        size_t => 'size',
    );
}

package Temporalio::Core::FFI::LoggingOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreLoggingOptions
    #   { TemporalCoreByteArrayRef filter; TemporalCoreForwardedLogCallback forward_to; }
    record_layout_1(
        opaque => 'filter_data',
        size_t => 'filter_size',
        opaque => 'forward_to',
    );
}

package Temporalio::Core::FFI::TelemetryOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreTelemetryOptions
    #   { const TemporalCoreLoggingOptions *logging; const TemporalCoreMetricsOptions *metrics; }
    record_layout_1(
        opaque => 'logging',
        opaque => 'metrics',
    );
}

package Temporalio::Core::FFI::RuntimeOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreRuntimeOptions
    #   { const TemporalCoreTelemetryOptions *telemetry; uint64_t worker_heartbeat_interval_millis; }
    record_layout_1(
        opaque => 'telemetry',
        uint64 => 'worker_heartbeat_interval_millis',
    );
}

package Temporalio::Core::FFI::RuntimeOrFail {
    use FFI::Platypus::Record;
    # struct TemporalCoreRuntimeOrFail
    #   { TemporalCoreRuntime *runtime; const TemporalCoreByteArray *fail; }
    # Returned BY VALUE from temporal_core_runtime_new.
    record_layout_1(
        opaque => 'runtime',
        opaque => 'fail',
    );
}

package Temporalio::Core::FFI;

our $VERSION = '0.1.0';

use FFI::Platypus 2.00;
use Alien::Temporalio::Core      ();
use Alien::Temporalio::PerlBridge ();

my @libs = (
    Alien::Temporalio::Core->dynamic_libs,
    Alien::Temporalio::PerlBridge->dynamic_libs,
);

for my $lib (@libs) {
    next if -f $lib;
    die "Temporalio::Core::FFI: shared library '$lib' cannot be loaded: $!\n";
}

my $ffi = FFI::Platypus->new(api => 2);
$ffi->lib(@libs);

# Opaque pointer aliases for every C struct we only ever handle by pointer.
$ffi->type('opaque' => $_) for qw(
    TemporalCoreRuntime
    TemporalCoreConnection
    TemporalCoreWorker
    TemporalCoreCancellationToken
    TemporalCoreByteArray
    TemporalCoreEphemeralServer
    TemporalioPerlBridgeQueue
);

# Record type aliases for the by-value structs declared above.
$ffi->type('record(Temporalio::Core::FFI::ByteArrayRef)'     => 'TemporalCoreByteArrayRef');
$ffi->type('record(Temporalio::Core::FFI::LoggingOptions)'   => 'TemporalCoreLoggingOptions');
$ffi->type('record(Temporalio::Core::FFI::TelemetryOptions)' => 'TemporalCoreTelemetryOptions');
$ffi->type('record(Temporalio::Core::FFI::RuntimeOptions)'   => 'TemporalCoreRuntimeOptions');
$ffi->type('record(Temporalio::Core::FFI::RuntimeOrFail)'    => 'TemporalCoreRuntimeOrFail');

# Phase-0 attach set: (C symbol, wrapper name, argument types, return type).
# Wrapper names drop the temporal_core_ / temporalio_perl_bridge_ prefix.
# Signatures transcribed from temporal-sdk-core-c-bridge.h and
# temporalio-perl-bridge.h at the pinned tag — never from memory.
my @phase0_attach = (
    # sdk-core-c-bridge
    [ temporal_core_runtime_new => 'runtime_new',
      [ 'record(Temporalio::Core::FFI::RuntimeOptions)*' ] => 'TemporalCoreRuntimeOrFail' ],
    [ temporal_core_runtime_free => 'runtime_free',
      [ 'TemporalCoreRuntime' ] => 'void' ],
    [ temporal_core_byte_array_free => 'byte_array_free',
      [ 'TemporalCoreRuntime', 'TemporalCoreByteArray' ] => 'void' ],
    [ temporal_core_cancellation_token_new => 'cancellation_token_new',
      [] => 'TemporalCoreCancellationToken' ],
    [ temporal_core_cancellation_token_cancel => 'cancellation_token_cancel',
      [ 'TemporalCoreCancellationToken' ] => 'void' ],
    [ temporal_core_cancellation_token_free => 'cancellation_token_free',
      [ 'TemporalCoreCancellationToken' ] => 'void' ],

    # temporalio-perl-bridge
    [ temporalio_perl_bridge_queue_new => 'queue_new',
      [ 'sint32' ] => 'TemporalioPerlBridgeQueue' ],
    [ temporalio_perl_bridge_queue_free => 'queue_free',
      [ 'TemporalioPerlBridgeQueue' ] => 'void' ],
    [ temporalio_perl_bridge_queue_drain => 'queue_drain',
      [ 'TemporalioPerlBridgeQueue', 'opaque', 'size_t' ] => 'size_t' ],
    [ temporalio_perl_bridge_user_data_new => 'user_data_new',
      [ 'TemporalioPerlBridgeQueue', 'uint64' ] => 'opaque' ],
    [ temporalio_perl_bridge_worker_poll_callback_ptr => 'worker_poll_callback_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_worker_callback_ptr => 'worker_callback_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_client_connect_callback_ptr => 'client_connect_callback_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_client_rpc_call_callback_ptr => 'client_rpc_call_callback_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_ephemeral_server_start_callback_ptr => 'ephemeral_server_start_callback_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_ephemeral_server_shutdown_callback_ptr => 'ephemeral_server_shutdown_callback_ptr',
      [] => 'opaque' ],
);

# Attach eagerly at load time and die loudly on any failure so a version
# skew between the SDK and the compiled bridge surfaces at import, not at
# the first call (spec section 4.1 failure modes).
for my $entry (@phase0_attach) {
    my ($c_name, $wrapper, $args, $ret) = @$entry;
    my $attached = eval { $ffi->attach([ $c_name => $wrapper ], $args, $ret); 1 };
    die "Temporalio::Core::FFI: failed to attach $c_name as $wrapper"
        . " (version skew with the compiled bridge libraries @libs?): $@"
        unless $attached;
}

1;

__END__

=head1 NAME

Temporalio::Core::FFI - FFI::Platypus bindings over the Temporal core C bridge

=head1 SYNOPSIS

    use Temporalio::Core::FFI;

    my $options = Temporalio::Core::FFI::RuntimeOptions->new(
        telemetry                        => undef,
        worker_heartbeat_interval_millis => 0,
    );
    my $result = Temporalio::Core::FFI::runtime_new($options);
    die 'runtime creation failed' if defined $result->fail;
    Temporalio::Core::FFI::runtime_free($result->runtime);

=head1 DESCRIPTION

Holds the single process-wide L<FFI::Platypus> instance (api 2) loaded with
both C<libtemporalio_sdk_core_c_bridge> (via L<Alien::Temporalio::Core>) and
C<libtemporalio_perl_bridge> (via L<Alien::Temporalio::PerlBridge>), and
attaches every C ABI function the SDK needs. Wrapper subs drop the
C<temporal_core_> / C<temporalio_perl_bridge_> prefixes.

Structs passed by value are declared as L<FFI::Platypus::Record> classes
under the C<Temporalio::Core::FFI::*> namespace. Both library load failures
and attach failures (version skew) die at module load time.

=cut
