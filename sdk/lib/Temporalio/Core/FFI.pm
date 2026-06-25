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

package Temporalio::Core::FFI::CallbackEntry {
    use FFI::Platypus::Record;
    # struct TemporalioPerlBridgeEntry (temporalio-perl-bridge.h): one queued
    # completion popped by temporalio_perl_bridge_queue_drain. kind (1..6 in
    # trampoline order, 7 for forwarded logs) discriminates which fields are
    # meaningful. Only ever handled BY POINTER into the drain buffer;
    # record_layout_1 inserts the same interior padding as the C layout
    # (callback_id 0, kind 8 + 7 pad, pointers 16/24/32, rpc_status_code 40 + 4
    # pad, pointers 48/56, the kind-7 log buffers 64/72/80, log_timestamp_ms
    # 88, sizeof 96) so casting buffer + i * sizeof views slot i.
    # For a kind-7 entry rpc_status_code carries the forwarded log level
    # (0..4); log_target/log_message/log_fields_json are shim-owned
    # NUL-terminated C strings freed via forwarded_log_free after the drain.
    record_layout_1(
        uint64 => 'callback_id',
        uint8  => 'kind',
        opaque => 'success_ba',
        opaque => 'fail_ba',
        opaque => 'success_handle',
        uint32 => 'rpc_status_code',
        opaque => 'rpc_failure_details',
        opaque => 'ephemeral_target',
        opaque => 'log_target',
        opaque => 'log_message',
        opaque => 'log_fields_json',
        uint64 => 'log_timestamp_ms',
    );
}

package Temporalio::Core::FFI::TestServerOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreTestServerOptions (testing.rs / header): five
    # ByteArrayRef members flattened to (data, size) pairs. Empty refs mean
    # "default behavior"; with existing_path set the download_* fields are
    # ignored, otherwise download_version 'default' selects the SDK-default
    # lookup keyed on sdk_name/sdk_version. Layout verified against the
    # pinned header with a gcc offsetof probe: port at 80 (+6 pad),
    # extra_args at 88, download_ttl_seconds at 104, sizeof 112.
    record_layout_1(
        opaque => 'existing_path_data',
        size_t => 'existing_path_size',
        opaque => 'sdk_name_data',
        size_t => 'sdk_name_size',
        opaque => 'sdk_version_data',
        size_t => 'sdk_version_size',
        opaque => 'download_version_data',
        size_t => 'download_version_size',
        opaque => 'download_dest_dir_data',
        size_t => 'download_dest_dir_size',
        uint16 => 'port',
        opaque => 'extra_args_data',
        size_t => 'extra_args_size',
        uint64 => 'download_ttl_seconds',
    );
}

package Temporalio::Core::FFI::DevServerOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreDevServerOptions (testing.rs / header): test_server
    # must always point at a TemporalCoreTestServerOptions. Layout verified
    # against the pinned header with a gcc offsetof probe: ui at 56 (bool),
    # ui_port at 58 (+1 pad), log_format at 64 (+4 pad), log_level at 80,
    # sizeof 96 — record_layout_1 inserts the same padding.
    record_layout_1(
        opaque => 'test_server',
        opaque => 'namespace_data',
        size_t => 'namespace_size',
        opaque => 'ip_data',
        size_t => 'ip_size',
        opaque => 'database_filename_data',
        size_t => 'database_filename_size',
        bool   => 'ui',
        uint16 => 'ui_port',
        opaque => 'log_format_data',
        size_t => 'log_format_size',
        opaque => 'log_level_data',
        size_t => 'log_level_size',
    );
}

package Temporalio::Core::FFI::ClientTlsOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreClientTlsOptions (client.rs / header): four
    # ByteArrayRef members flattened to (data, size) pairs. NULL refs mean
    # "unset": system CA roots, no SNI override, no mTLS pair. The bridge
    # requires client_cert and client_private_key to be both set or both
    # NULL (Temporalio::Client::TlsConfig enforces this Perl-side).
    record_layout_1(
        opaque => 'server_root_ca_cert_data',
        size_t => 'server_root_ca_cert_size',
        opaque => 'domain_data',
        size_t => 'domain_size',
        opaque => 'client_cert_data',
        size_t => 'client_cert_size',
        opaque => 'client_private_key_data',
        size_t => 'client_private_key_size',
    );
}

package Temporalio::Core::FFI::ClientRetryOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreClientRetryOptions (client.rs / header):
    #   { uint64_t initial_interval_millis; double randomization_factor;
    #     double multiplier; uint64_t max_interval_millis;
    #     uint64_t max_elapsed_time_millis; uintptr_t max_retries; }
    # max_elapsed_time_millis 0 maps to None (unlimited) in the bridge.
    record_layout_1(
        uint64 => 'initial_interval_millis',
        double => 'randomization_factor',
        double => 'multiplier',
        uint64 => 'max_interval_millis',
        uint64 => 'max_elapsed_time_millis',
        size_t => 'max_retries',
    );
}

package Temporalio::Core::FFI::ClientKeepAliveOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreClientKeepAliveOptions
    #   { uint64_t interval_millis; uint64_t timeout_millis; }
    record_layout_1(
        uint64 => 'interval_millis',
        uint64 => 'timeout_millis',
    );
}

package Temporalio::Core::FFI::ConnectionOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreConnectionOptions (client.rs / header): seven
    # ByteArrayRef/MetadataRef members flattened to (data, size) pairs,
    # then seven pointer members. NOTE: metadata and binary_metadata are
    # TemporalCoreMetadataRef (= ByteArrayRefArray), so their _data points
    # at a packed array of ByteArrayRef structs and their _size is the
    # ENTRY COUNT, not a byte length — build them with
    # Temporalio::Core::FFI::keep_byte_array_ref_array. Every member is
    # 8-aligned on x86-64, so the record layout has no interior padding.
    record_layout_1(
        opaque => 'target_url_data',
        size_t => 'target_url_size',
        opaque => 'client_name_data',
        size_t => 'client_name_size',
        opaque => 'client_version_data',
        size_t => 'client_version_size',
        opaque => 'metadata_data',
        size_t => 'metadata_size',
        opaque => 'binary_metadata_data',
        size_t => 'binary_metadata_size',
        opaque => 'api_key_data',
        size_t => 'api_key_size',
        opaque => 'identity_data',
        size_t => 'identity_size',
        opaque => 'tls_options',
        opaque => 'retry_options',
        opaque => 'keep_alive_options',
        opaque => 'http_connect_proxy_options',
        opaque => 'grpc_override_callback',
        opaque => 'grpc_override_callback_user_data',
        opaque => 'dns_load_balancing_options',
    );
}

package Temporalio::Core::FFI::RpcCallOptions {
    use FFI::Platypus::Record;
    # struct TemporalCoreRpcCallOptions (client.rs / header): the service
    # discriminator (repr(C) enum: Workflow=1, Operator, Cloud, Test,
    # Health), two ByteArrayRef members (rpc name, serialized request proto)
    # flattened to (data, size) pairs, the retry flag (core, not Perl,
    # applies the client RetryConfig - spec section 7.5), two MetadataRef
    # members (entry-count sized; build with keep_byte_array_ref_array),
    # timeout_millis (0 = no timeout), and an optional cancellation token.
    # Layout verified against the pinned header with a gcc offsetof probe:
    # service at 0 (+4 pad), rpc at 8, req at 24, retry at 40 (+7 pad),
    # metadata at 48, binary_metadata at 64, timeout_millis at 80 (+4 pad),
    # cancellation_token at 88, sizeof 96 - record_layout_1 inserts the same
    # padding.
    record_layout_1(
        uint32 => 'service',
        opaque => 'rpc_data',
        size_t => 'rpc_size',
        opaque => 'req_data',
        size_t => 'req_size',
        bool   => 'retry',
        opaque => 'metadata_data',
        size_t => 'metadata_size',
        opaque => 'binary_metadata_data',
        size_t => 'binary_metadata_size',
        uint32 => 'timeout_millis',
        opaque => 'cancellation_token',
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

package Temporalio::Core::FFI::CustomMetricMeter {
    use FFI::Platypus::Record;
    # struct TemporalCoreCustomMetricMeter (spec section 28.2): eight function
    # pointers core invokes for every metric create/record. We fill each with a
    # shim trampoline pointer (the shim aggregates records and main-thread-
    # marshals create/free). Held BY POINTER as MetricsOptions.custom_meter.
    record_layout_1(
        opaque => 'metric_new',
        opaque => 'metric_free',
        opaque => 'metric_record_integer',
        opaque => 'metric_record_float',
        opaque => 'metric_record_duration',
        opaque => 'attributes_new',
        opaque => 'attributes_free',
        opaque => 'meter_free',
    );
}

package Temporalio::Core::FFI::MeterRecord {
    use FFI::Platypus::Record;
    # struct TemporalioPerlBridgeMeterRecord (temporalio-perl-bridge.h): one
    # drained aggregation bucket. record_layout_1 inserts the same padding as
    # the C repr(C) layout (metric_id 0, attributes_id 8, record_kind 16 + 7
    # pad, value 24, count 32, sizeof 40) so casting buffer + i * sizeof views
    # slot i. Only ever handled BY POINTER into the record-drain buffer.
    record_layout_1(
        uint64 => 'metric_id',
        uint64 => 'attributes_id',
        uint8  => 'record_kind',
        double => 'value',
        uint64 => 'count',
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

package Temporalio::Core::FFI::WorkerOrFail {
    use FFI::Platypus::Record;
    # struct TemporalCoreWorkerOrFail
    #   { TemporalCoreWorker *worker; const TemporalCoreByteArray *fail; }
    # Returned BY VALUE from temporal_core_worker_new (header: "Only worker or
    # fail will be non-null. Whichever is must be freed when done.").
    record_layout_1(
        opaque => 'worker',
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
$ffi->type('record(Temporalio::Core::FFI::ClientTlsOptions)'       => 'TemporalCoreClientTlsOptions');
$ffi->type('record(Temporalio::Core::FFI::ClientRetryOptions)'     => 'TemporalCoreClientRetryOptions');
$ffi->type('record(Temporalio::Core::FFI::ClientKeepAliveOptions)' => 'TemporalCoreClientKeepAliveOptions');
$ffi->type('record(Temporalio::Core::FFI::ConnectionOptions)'      => 'TemporalCoreConnectionOptions');
$ffi->type('record(Temporalio::Core::FFI::RpcCallOptions)'         => 'TemporalCoreRpcCallOptions');
$ffi->type('record(Temporalio::Core::FFI::TestServerOptions)'    => 'TemporalCoreTestServerOptions');
$ffi->type('record(Temporalio::Core::FFI::DevServerOptions)'     => 'TemporalCoreDevServerOptions');
$ffi->type('record(Temporalio::Core::FFI::LoggingOptions)'       => 'TemporalCoreLoggingOptions');
$ffi->type('record(Temporalio::Core::FFI::OpenTelemetryOptions)' => 'TemporalCoreOpenTelemetryOptions');
$ffi->type('record(Temporalio::Core::FFI::PrometheusOptions)'    => 'TemporalCorePrometheusOptions');
$ffi->type('record(Temporalio::Core::FFI::MetricsOptions)'       => 'TemporalCoreMetricsOptions');
$ffi->type('record(Temporalio::Core::FFI::CustomMetricMeter)'    => 'TemporalCoreCustomMetricMeter');
$ffi->type('record(Temporalio::Core::FFI::TelemetryOptions)'     => 'TemporalCoreTelemetryOptions');
$ffi->type('record(Temporalio::Core::FFI::RuntimeOptions)'       => 'TemporalCoreRuntimeOptions');
$ffi->type('record(Temporalio::Core::FFI::RuntimeOrFail)'        => 'TemporalCoreRuntimeOrFail');
$ffi->type('record(Temporalio::Core::FFI::WorkerOrFail)'         => 'TemporalCoreWorkerOrFail');

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

# keep_byte_array_ref_array(\@keep, \@strings) — packs a contiguous array
# of TemporalCoreByteArrayRef structs (one per string) into kept memory and
# returns ($data_ptr, $count) for a TemporalCoreByteArrayRefArray member
# (e.g. TemporalCoreMetadataRef, whose entries are each "key\nvalue").
# pack('Q') assumes LP64 little-endian, the same x86-64 SysV assumption as
# Temporalio::Core::FFI::WorkerOptions. Returns (undef, 0) for undef/empty.
sub keep_byte_array_ref_array ($keep, $strings) {
    return (undef, 0) unless defined $strings && @$strings;
    my $elements = '';
    for my $string (@$strings) {
        my ($data, $size) = keep_buffer($keep, $string);
        $elements .= pack('Q Q', $data, $size);
    }
    my ($elements_ptr) = keep_buffer($keep, $elements);
    return ($elements_ptr, scalar @$strings);
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
    # Client connect/free/api-key rotation (spec section 7.3). The connect
    # callback arguments are the shim trampoline pointer (connect kind) and
    # the shim (queue, callback_id) user_data pair, both passed as opaque.
    # Per client.rs: the runtime must live as long as the client, and the
    # options struct must live through the callback.
    [ temporal_core_client_connect => 'client_connect',
      [ 'TemporalCoreRuntime', 'record(Temporalio::Core::FFI::ConnectionOptions)*',
        'opaque', 'opaque' ] => 'void' ],
    [ temporal_core_client_free => 'client_free',
      [ 'TemporalCoreConnection' ] => 'void' ],
    [ temporal_core_client_update_api_key => 'client_update_api_key',
      [ 'TemporalCoreConnection', 'TemporalCoreByteArrayRef' ] => 'void' ],
    # Raw RPC call (spec sections 7.3/7.5). The callback arguments are the
    # shim trampoline pointer (rpc kind) and the shim (queue, callback_id)
    # user_data pair, both passed as opaque. Per the header: "Client,
    # options, and user data must live through callback."
    [ temporal_core_client_rpc_call => 'client_rpc_call',
      [ 'TemporalCoreConnection', 'record(Temporalio::Core::FFI::RpcCallOptions)*',
        'opaque', 'opaque' ] => 'void' ],
    # Ephemeral dev server (spec section 12.2). The callback arguments are
    # the shim trampoline pointers (server_start / server_shutdown kinds),
    # passed as opaque; user_data is the shim (queue, callback_id) pair.
    # Per testing.rs: the runtime must outlive the server, and the shutdown
    # async block borrows the server box — free only after the shutdown
    # callback has fired.
    [ temporal_core_ephemeral_server_start_dev_server => 'ephemeral_server_start_dev_server',
      [ 'TemporalCoreRuntime', 'record(Temporalio::Core::FFI::DevServerOptions)*',
        'opaque', 'opaque' ] => 'void' ],
    [ temporal_core_ephemeral_server_shutdown => 'ephemeral_server_shutdown',
      [ 'TemporalCoreEphemeralServer', 'opaque', 'opaque' ] => 'void' ],
    [ temporal_core_ephemeral_server_free => 'ephemeral_server_free',
      [ 'TemporalCoreEphemeralServer' ] => 'void' ],
    # Worker construction + validate + shutdown (spec sections 8.1-8.2).
    # worker_new takes a pointer to the hand-packed TemporalCoreWorkerOptions
    # buffer (Temporalio::Core::FFI::WorkerOptions, passed as opaque) and
    # returns the worker-or-fail union BY VALUE. validate and
    # finalize_shutdown are async (callback bridge, 'worker' kind); the
    # callback arguments are the shim trampoline pointer and the (queue,
    # callback_id) user_data pair, both opaque. initiate_shutdown and free
    # are synchronous (header: initiate then finalize then free).
    [ temporal_core_worker_new => 'worker_new',
      [ 'TemporalCoreConnection', 'opaque' ] => 'TemporalCoreWorkerOrFail' ],
    [ temporal_core_worker_validate => 'worker_validate',
      [ 'TemporalCoreWorker', 'opaque', 'opaque' ] => 'void' ],
    [ temporal_core_worker_initiate_shutdown => 'worker_initiate_shutdown',
      [ 'TemporalCoreWorker' ] => 'void' ],
    [ temporal_core_worker_finalize_shutdown => 'worker_finalize_shutdown',
      [ 'TemporalCoreWorker', 'opaque', 'opaque' ] => 'void' ],
    [ temporal_core_worker_free => 'worker_free',
      [ 'TemporalCoreWorker' ] => 'void' ],
    # Activity poll + complete (spec section 8.4). Both are async (callback
    # bridge): poll uses the 'worker_poll' kind (a TemporalCoreWorkerPollCallback
    # returning the serialized ActivityTask byte array, or null/null on
    # ShutDown); complete uses the 'worker' kind (a TemporalCoreWorkerCallback,
    # fail-or-nothing). poll takes (worker, user_data, callback); complete takes
    # (worker, ByteArrayRef completion, user_data, callback) — the completion
    # ByteArrayRef (a serialized coresdk.ActivityTaskCompletion) must live
    # through the callback, so the issuing code holds the buffer until the
    # Future resolves. Both callback args (trampoline + user_data pair) pass as
    # opaque, matching worker_validate.
    [ temporal_core_worker_poll_activity_task => 'worker_poll_activity_task',
      [ 'TemporalCoreWorker', 'opaque', 'opaque' ] => 'void' ],
    [ temporal_core_worker_complete_activity_task => 'worker_complete_activity_task',
      [ 'TemporalCoreWorker', 'TemporalCoreByteArrayRef', 'opaque', 'opaque' ]
        => 'void' ],
    # Workflow poll/complete (spec section 8.3). Same shapes as the activity
    # pair: poll uses the 'worker_poll' kind (a TemporalCoreWorkerPollCallback
    # returning the serialized WorkflowActivation byte array, or null/null on
    # ShutDown); complete uses the 'worker' kind (a TemporalCoreWorkerCallback,
    # fail-or-nothing) and takes the serialized WorkflowActivationCompletion as a
    # ByteArrayRef that must live through the callback.
    [ temporal_core_worker_poll_workflow_activation => 'worker_poll_workflow_activation',
      [ 'TemporalCoreWorker', 'opaque', 'opaque' ] => 'void' ],
    [ temporal_core_worker_complete_workflow_activation => 'worker_complete_workflow_activation',
      [ 'TemporalCoreWorker', 'TemporalCoreByteArrayRef', 'opaque', 'opaque' ]
        => 'void' ],
    # Activity heartbeat (spec section 9.3, T-act-7). SYNCHRONOUS, not a
    # callback bridge call: the bridge serializes the coresdk.ActivityHeartbeat
    # proto we pass as a ByteArrayRef and returns NULL on success or an owned
    # TemporalCoreByteArray describing the error ("Returns error if any. Must be
    # freed if returned." — header). The Perl side wraps the return with
    # Temporalio::Core::ByteArray to read + free it.
    [ temporal_core_worker_record_activity_heartbeat => 'worker_record_activity_heartbeat',
      [ 'TemporalCoreWorker', 'TemporalCoreByteArrayRef' ] => 'TemporalCoreByteArray' ],

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
    # Log forwarding (spec section 28.1, kind 7). The forward_to trampoline
    # has no user_data, so it routes via a process-global registry:
    # forwarding_register claims it for a queue (returns false if a second
    # runtime requests forwarding while one is active -> Perl raises Argument),
    # forwarding_unregister releases it at shutdown. forwarded_log_callback_ptr
    # is the TemporalCoreForwardedLogCallback for the LoggingOptions forward_to
    # slot. forwarded_log_free frees a drained kind-7 entry's shim-owned target/
    # message/fields buffers (undrained entries are freed by the shim's Drop at
    # queue_free).
    # forwarding_register takes the queue plus the four core forwarded-log
    # accessor function pointers (passed as opaque). The shim never hard-links
    # the core bridge — FFI::Platypus loads each library RTLD_LOCAL, so the
    # shim's undefined symbols would not resolve against the separately loaded
    # core lib; instead Perl hands the accessors it resolved itself.
    [ temporalio_perl_bridge_forwarding_register => 'forwarding_register',
      [ 'TemporalioPerlBridgeQueue', 'opaque', 'opaque', 'opaque', 'opaque' ]
        => 'bool' ],
    [ temporalio_perl_bridge_forwarding_unregister => 'forwarding_unregister',
      [ 'TemporalioPerlBridgeQueue' ] => 'void' ],
    [ temporalio_perl_bridge_forwarded_log_callback_ptr => 'forwarded_log_callback_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_forwarded_log_free => 'forwarded_log_free',
      [ 'opaque' ] => 'void' ],
    # Custom metric meters (spec section 28.2). Like log forwarding, the eight
    # TemporalCoreCustomMetricMeter callbacks route via a process-global
    # registry (only one runtime may carry a custom meter). meter_register
    # claims it for a queue (false if a second meter is active -> Argument).
    # The eight *_ptr accessors return the callback addresses Perl packs into
    # the TemporalCoreCustomMetricMeter. The shim aggregates record_* in pure
    # Rust; meter_drain_records pulls accumulated buckets on the main-thread
    # drain. metric_new/attributes_new/*_free NEVER block and NEVER call Perl
    # from the callback (the spike resolution: nested FFI re-entry would corrupt
    # libffi on repeated calls, and blocking on a main-thread drain would
    # self-deadlock): the shim allocates the handle id itself, returns it
    # immediately, and parks a request the drain runs. meter_next_request pops
    # the next parked request (read its fields via req_*), and
    # meter_free_request frees it after the drain runs the Perl method.
    [ temporalio_perl_bridge_meter_register => 'meter_register',
      [ 'TemporalioPerlBridgeQueue' ] => 'bool' ],
    [ temporalio_perl_bridge_meter_unregister => 'meter_unregister',
      [ 'TemporalioPerlBridgeQueue' ] => 'void' ],
    [ temporalio_perl_bridge_meter_metric_new_ptr => 'meter_metric_new_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_metric_free_ptr => 'meter_metric_free_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_record_integer_ptr => 'meter_record_integer_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_record_float_ptr => 'meter_record_float_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_record_duration_ptr => 'meter_record_duration_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_attributes_new_ptr => 'meter_attributes_new_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_attributes_free_ptr => 'meter_attributes_free_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_meter_free_ptr => 'meter_meter_free_ptr',
      [] => 'opaque' ],
    [ temporalio_perl_bridge_meter_next_request => 'meter_next_request',
      [ 'opaque' ] => 'opaque' ],
    [ temporalio_perl_bridge_meter_free_request => 'meter_free_request',
      [ 'opaque' ] => 'void' ],
    [ temporalio_perl_bridge_meter_drain_records => 'meter_drain_records',
      [ 'opaque', 'size_t' ] => 'size_t' ],
    [ temporalio_perl_bridge_meter_req_new_id => 'meter_req_new_id',
      [ 'opaque' ] => 'uint64' ],
    [ temporalio_perl_bridge_meter_req_name => 'meter_req_name',
      [ 'opaque' ] => 'TemporalCoreByteArrayRef' ],
    [ temporalio_perl_bridge_meter_req_description => 'meter_req_description',
      [ 'opaque' ] => 'TemporalCoreByteArrayRef' ],
    [ temporalio_perl_bridge_meter_req_unit => 'meter_req_unit',
      [ 'opaque' ] => 'TemporalCoreByteArrayRef' ],
    [ temporalio_perl_bridge_meter_req_kind => 'meter_req_kind',
      [ 'opaque' ] => 'sint32' ],
    [ temporalio_perl_bridge_meter_req_free_id => 'meter_req_free_id',
      [ 'opaque' ] => 'uint64' ],
    [ temporalio_perl_bridge_meter_req_append_from_id => 'meter_req_append_from_id',
      [ 'opaque' ] => 'uint64' ],
    [ temporalio_perl_bridge_meter_req_attr_count => 'meter_req_attr_count',
      [ 'opaque' ] => 'size_t' ],
    [ temporalio_perl_bridge_meter_req_attr_key => 'meter_req_attr_key',
      [ 'opaque', 'size_t' ] => 'TemporalCoreByteArrayRef' ],
    [ temporalio_perl_bridge_meter_req_attr_value_type => 'meter_req_attr_value_type',
      [ 'opaque', 'size_t' ] => 'sint32' ],
    [ temporalio_perl_bridge_meter_req_attr_string => 'meter_req_attr_string',
      [ 'opaque', 'size_t' ] => 'TemporalCoreByteArrayRef' ],
    [ temporalio_perl_bridge_meter_req_attr_int => 'meter_req_attr_int',
      [ 'opaque', 'size_t' ] => 'sint64' ],
    [ temporalio_perl_bridge_meter_req_attr_float => 'meter_req_attr_float',
      [ 'opaque', 'size_t' ] => 'double' ],
    [ temporalio_perl_bridge_meter_req_attr_bool => 'meter_req_attr_bool',
      [ 'opaque', 'size_t' ] => 'bool' ],
    # WorkerOptions marshalling spike (plan P0.10): the shim parses a
    # TemporalCoreWorkerOptions built Perl-side and echoes every field as a
    # NUL-terminated "field=value" summary string (cast it to 'string', then
    # release it with string_free).
    [ temporalio_perl_bridge_debug_worker_options => 'debug_worker_options',
      [ 'opaque' ] => 'opaque' ],
    [ temporalio_perl_bridge_string_free => 'string_free',
      [ 'opaque' ] => 'void' ],
);

# The four core forwarded-log accessor function pointers (spec section 28.1).
# Resolved from the loaded core bridge via FFI::Platypus find_symbol and
# handed to the shim's forwarding_register so the shim never hard-links core.
# Memoized: the symbols are stable for the process lifetime.
my %_forwarded_log_accessor_ptr;
sub forwarded_log_accessor_ptrs () {
    return @_forwarded_log_accessor_ptr{
        qw(target message timestamp_millis fields_json)
    } if %_forwarded_log_accessor_ptr;
    for my $name (qw(target message timestamp_millis fields_json)) {
        my $sym = "temporal_core_forwarded_log_$name";
        my $ptr = $ffi->find_symbol($sym)
            or die "Temporalio::Core::FFI: core bridge symbol '$sym' not found"
                 . ' (version skew with the compiled core bridge?)';
        $_forwarded_log_accessor_ptr{$name} = $ptr;
    }
    return @_forwarded_log_accessor_ptr{
        qw(target message timestamp_millis fields_json)
    };
}

# Custom metric meter (spec section 28.2) helpers.

# The eight TemporalCoreCustomMetricMeter callback pointers, in struct order.
# Memoized: the addresses are stable for the process lifetime.
my @_meter_callback_ptr;
sub meter_callback_ptrs () {
    @_meter_callback_ptr = (
        meter_metric_new_ptr(),
        meter_metric_free_ptr(),
        meter_record_integer_ptr(),
        meter_record_float_ptr(),
        meter_record_duration_ptr(),
        meter_attributes_new_ptr(),
        meter_attributes_free_ptr(),
        meter_meter_free_ptr(),
    ) unless @_meter_callback_ptr;
    return @_meter_callback_ptr;
}

# Read a TemporalCoreByteArrayRef returned by value (the meter req_* accessors)
# into a Perl string; a NULL data pointer yields the empty string.
sub byte_array_ref_to_scalar ($ref) {
    my $data = $ref->data;
    my $size = $ref->size;
    return '' unless defined $data && $size;
    return FFI::Platypus::Buffer::buffer_to_scalar($data, $size);
}

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

=encoding utf8

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

=head1 FUNCTIONS

This module exposes the SDK-internal C ABI as plain package subroutines whose
names drop the C<temporal_core_> / C<temporalio_perl_bridge_> prefixes (for
example C<runtime_new>, C<client_connect>, C<worker_poll_workflow_activation>).
They are an internal mechanism wrapped by the higher-level
L<Temporalio::Runtime>, L<Temporalio::Client>, and L<Temporalio::Worker>
classes and are not part of the public SDK surface; their contracts are the C
header at the pinned sdk-rust tag. They are therefore excluded from POD
coverage below.

=cut
