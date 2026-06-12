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

package Temporalio::Core::FFI::ByteArray {
    use FFI::Platypus::Record;
    # struct TemporalCoreByteArray
    #   { const uint8_t *data; size_t size; size_t cap; bool disable_free; }
    # Only ever handled BY POINTER (wrapped via Temporalio::Core::ByteArray
    # or crafted in tests); FFI::Platypus::Record omits the C struct's 7
    # bytes of trailing padding (25 vs 32), which is irrelevant for
    # pointer-only use — field offsets (0/8/16/24) match the C layout and
    # nothing reads past disable_free.
    record_layout_1(
        opaque => 'data',
        size_t => 'size',
        size_t => 'cap',
        bool   => 'disable_free',
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

package Temporalio::Core::FFI::OpenTelemetryOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreOpenTelemetryOptions
    #   { TemporalCoreByteArrayRef url; TemporalCoreNewlineDelimitedMapRef headers;
    #     uint32_t metric_periodicity_millis;
    #     enum TemporalCoreOpenTelemetryMetricTemporality metric_temporality;
    #     bool durations_as_seconds; enum TemporalCoreOpenTelemetryProtocol protocol;
    #     TemporalCoreNewlineDelimitedMapRef histogram_bucket_overrides; }
    # Enums are #[repr(C)] in runtime.rs (C int, 4 bytes): Cumulative=1/Delta=2,
    # Grpc=1/Http=2.
    record_layout_1(
        opaque => 'url_data',
        size_t => 'url_size',
        opaque => 'headers_data',
        size_t => 'headers_size',
        uint32 => 'metric_periodicity_millis',
        uint32 => 'metric_temporality',
        bool   => 'durations_as_seconds',
        uint32 => 'protocol',
        opaque => 'histogram_bucket_overrides_data',
        size_t => 'histogram_bucket_overrides_size',
    );
}

package Temporalio::Core::FFI::PrometheusOptions {
    use FFI::Platypus::Record;
    # struct TemporalCorePrometheusOptions
    #   { TemporalCoreByteArrayRef bind_address; bool counters_total_suffix;
    #     bool unit_suffix; bool durations_as_seconds;
    #     TemporalCoreNewlineDelimitedMapRef histogram_bucket_overrides; }
    record_layout_1(
        opaque => 'bind_address_data',
        size_t => 'bind_address_size',
        bool   => 'counters_total_suffix',
        bool   => 'unit_suffix',
        bool   => 'durations_as_seconds',
        opaque => 'histogram_bucket_overrides_data',
        size_t => 'histogram_bucket_overrides_size',
    );
}

package Temporalio::Core::FFI::MetricsOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreMetricsOptions
    #   { const TemporalCoreOpenTelemetryOptions *opentelemetry;
    #     const TemporalCorePrometheusOptions *prometheus;
    #     const TemporalCoreCustomMetricMeter *custom_meter;
    #     bool attach_service_name; TemporalCoreNewlineDelimitedMapRef global_tags;
    #     TemporalCoreByteArrayRef metric_prefix; }
    # Only one of opentelemetry/prometheus/custom_meter may be non-NULL
    # (enforced Perl-side by Temporalio::Runtime::TelemetryConfig, T-rt-4).
    record_layout_1(
        opaque => 'opentelemetry',
        opaque => 'prometheus',
        opaque => 'custom_meter',
        bool   => 'attach_service_name',
        opaque => 'global_tags_data',
        size_t => 'global_tags_size',
        opaque => 'metric_prefix_data',
        size_t => 'metric_prefix_size',
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
use FFI::Platypus::Buffer ();
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

# The process-wide FFI::Platypus instance, exposed for cast() by the thin
# object wrappers (e.g. Temporalio::Core::ByteArray reads struct fields by
# casting an opaque pointer to a record view).
sub ffi { $ffi }

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
$ffi->type('record(Temporalio::Core::FFI::ByteArrayRef)'         => 'TemporalCoreByteArrayRef');
$ffi->type('record(Temporalio::Core::FFI::LoggingOptions)'       => 'TemporalCoreLoggingOptions');
$ffi->type('record(Temporalio::Core::FFI::OpenTelemetryOptions)' => 'TemporalCoreOpenTelemetryOptions');
$ffi->type('record(Temporalio::Core::FFI::PrometheusOptions)'    => 'TemporalCorePrometheusOptions');
$ffi->type('record(Temporalio::Core::FFI::MetricsOptions)'       => 'TemporalCoreMetricsOptions');
$ffi->type('record(Temporalio::Core::FFI::TelemetryOptions)'     => 'TemporalCoreTelemetryOptions');
$ffi->type('record(Temporalio::Core::FFI::RuntimeOptions)'       => 'TemporalCoreRuntimeOptions');
$ffi->type('record(Temporalio::Core::FFI::RuntimeOrFail)'        => 'TemporalCoreRuntimeOrFail');

# --- Marshalling helpers for the by-pointer record trees -------------------
#
# Records hold raw pointers into Perl-owned memory; the @$keep arrayref
# pattern makes those lifetimes explicit. Callers allocate one @keep per
# bridge call (e.g. runtime_new), thread it through every to_ffi builder,
# and hold it until the call returns.

# keep_buffer(\@keep, $scalar) — returns the (data, size) pair for a copy of
# $scalar, pushing the copy onto @$keep so the pointer stays valid. Returns
# (undef, 0) for undef (a NULL TemporalCoreByteArrayRef).
sub keep_buffer ($keep, $scalar) {
    return (undef, 0) unless defined $scalar;
    my $copy = $scalar;    # private copy: caller's SV may be modified/freed
    push @$keep, \$copy;
    return FFI::Platypus::Buffer::scalar_to_buffer($copy);
}

# keep_record(\@keep, $record) — pushes the record object onto @$keep and
# returns its address as an opaque pointer (for struct members that hold a
# pointer to another struct).
sub keep_record ($keep, $record) {
    push @$keep, $record;
    return $ffi->cast('record(' . ref($record) . ')*' => 'opaque', $record);
}

# encode_newline_map($hashref) — encodes a hash as the C bridge's
# TemporalCoreNewlineDelimitedMapRef payload: "k1\nv1\nk2\nv2" (keys sorted
# for determinism). Keys and values cannot contain newlines (per the header).
# Returns undef for undef/empty (a NULL map ref).
sub encode_newline_map ($map) {
    return undef unless defined $map && %$map;
    my @parts;
    for my $key (sort keys %$map) {
        my $value = $map->{$key} // '';
        if ("$key$value" =~ /\n/) {
            require Temporalio::Exception::Argument;
            Temporalio::Exception::Argument->throw(
                message => 'newline-delimited map keys and values must not'
                         . " contain newlines (key '$key')",
            );
        }
        push @parts, $key, $value;
    }
    return join "\n", @parts;
}

# encode_bucket_overrides($hashref) — histogram bucket overrides as a
# newline-delimited map of "metric" => "f1,f2,f3" (per the header comment on
# histogram_bucket_overrides).
sub encode_bucket_overrides ($overrides) {
    return undef unless defined $overrides && %$overrides;
    return encode_newline_map({
        map { $_ => join(',', @{ $overrides->{$_} }) } keys %$overrides,
    });
}

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
    # WorkerOptions marshalling spike (plan P0.10): the shim parses a
    # TemporalCoreWorkerOptions built Perl-side and echoes every field as a
    # NUL-terminated "field=value" summary string (cast it to 'string', then
    # release it with string_free).
    [ temporalio_perl_bridge_debug_worker_options => 'debug_worker_options',
      [ 'opaque' ] => 'opaque' ],
    [ temporalio_perl_bridge_string_free => 'string_free',
      [ 'opaque' ] => 'void' ],
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
