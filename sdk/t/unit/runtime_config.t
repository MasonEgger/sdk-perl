# ABOUTME: Tests the telemetry config classes (spec section 4.2): TelemetryConfig
# ABOUTME: both-exporters rejection (T-rt-4), LoggingFilter string (T-rt-6),
# ABOUTME: OTel/Prometheus field validation, and the to_ffi record builders.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();

# Spec section 4.2 config classes. Pure validation plus to_ffi field-value
# assertions — record layout verification is P0.10's job.

my @classes = qw(
    Temporalio::Runtime::TelemetryConfig
    Temporalio::Runtime::LoggingConfig
    Temporalio::Runtime::LoggingFilter
    Temporalio::Runtime::OpenTelemetryConfig
    Temporalio::Runtime::PrometheusConfig
);

T2->subtest('modules load' => sub {
    for my $class (@classes) {
        my $loaded = eval "require $class; 1";
        T2->ok($loaded, "require $class succeeds") or T2->diag($@);
    }
});

# Captures the exception a code block dies with; returns it (or undef).
sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub is_argument_exc ($err) {
    return Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument');
}

T2->subtest('LoggingFilter produces the cross-SDK filter string (T-rt-6)' => sub {
    # Format verified against sdk-ruby runtime.rb (LoggingFilterOptions::_to_bridge)
    # and sdk-python runtime.py (TelemetryFilter.formatted): the other_level
    # first, then each Rust target pinned to core_level. The fourth target is
    # this SDK's own bridge crate (temporalio-perl-bridge).
    my $filter = Temporalio::Runtime::LoggingFilter->new(
        core_level  => 'INFO',
        other_level => 'WARN',
    );
    T2->is(
        $filter->to_string,
        'WARN,temporalio_sdk_core=INFO,temporalio_client=INFO,'
            . 'temporalio_sdk=INFO,temporalio_perl_bridge=INFO',
        'INFO/WARN filter matches the reference SDK format',
    );

    # Defaults match Python LoggingConfig.default and Ruby LoggingFilterOptions:
    # core WARN, other ERROR.
    T2->is(
        Temporalio::Runtime::LoggingFilter->new->to_string,
        'ERROR,temporalio_sdk_core=WARN,temporalio_client=WARN,'
            . 'temporalio_sdk=WARN,temporalio_perl_bridge=WARN',
        'default filter is core WARN / other ERROR',
    );

    for my $bad_field (qw(core_level other_level)) {
        my $err = exception_from(sub {
            Temporalio::Runtime::LoggingFilter->new($bad_field => 'LOUD');
        });
        T2->ok(is_argument_exc($err), "invalid $bad_field raises Argument")
            or T2->diag("got: " . ($err // 'no exception'));
    }
});

T2->subtest('LoggingConfig wraps a filter or raw string' => sub {
    my $default = Temporalio::Runtime::LoggingConfig->default;
    T2->isa_ok($default, 'Temporalio::Runtime::LoggingConfig');
    T2->is(
        $default->filter_string,
        Temporalio::Runtime::LoggingFilter->new->to_string,
        'default config uses the default filter',
    );

    my $raw = Temporalio::Runtime::LoggingConfig->new(filter => 'temporal_sdk_core=DEBUG');
    T2->is($raw->filter_string, 'temporal_sdk_core=DEBUG',
        'raw string filter passes through unchanged');

    my $err = exception_from(sub {
        Temporalio::Runtime::LoggingConfig->new(filter => { level => 'INFO' });
    });
    T2->ok(is_argument_exc($err),
        'non-LoggingFilter reference raises Argument')
        or T2->diag("got: " . ($err // 'no exception'));
});

T2->subtest('OpenTelemetryConfig field validation' => sub {
    my $otel = Temporalio::Runtime::OpenTelemetryConfig->new(url => 'http://otel:4317');
    T2->is($otel->url,                'http://otel:4317', 'url accessor');
    T2->is($otel->metric_temporality, 'cumulative',       'temporality defaults to cumulative');
    T2->is($otel->protocol,           'grpc',             'protocol defaults to grpc');

    my $temporality_err = exception_from(sub {
        Temporalio::Runtime::OpenTelemetryConfig->new(
            url                => 'http://otel:4317',
            metric_temporality => 'sometimes',
        );
    });
    T2->ok(is_argument_exc($temporality_err),
        'bad metric_temporality string raises Argument')
        or T2->diag("got: " . ($temporality_err // 'no exception'));

    my $protocol_err = exception_from(sub {
        Temporalio::Runtime::OpenTelemetryConfig->new(
            url      => 'http://otel:4317',
            protocol => 'carrier-pigeon',
        );
    });
    T2->ok(is_argument_exc($protocol_err), 'bad protocol raises Argument')
        or T2->diag("got: " . ($protocol_err // 'no exception'));

    T2->ok(exception_from(sub { Temporalio::Runtime::OpenTelemetryConfig->new }),
        'missing url dies');
});

T2->subtest('PrometheusConfig field validation' => sub {
    my $prom = Temporalio::Runtime::PrometheusConfig->new(bind_address => '0.0.0.0:9464');
    T2->is($prom->bind_address, '0.0.0.0:9464', 'bind_address accessor');
    T2->ok(!$prom->counters_total_suffix, 'counters_total_suffix defaults false');
    T2->ok(!$prom->unit_suffix,           'unit_suffix defaults false');
    T2->ok(!$prom->durations_as_seconds,  'durations_as_seconds defaults false');

    T2->ok(exception_from(sub { Temporalio::Runtime::PrometheusConfig->new }),
        'missing bind_address dies');
});

T2->subtest('TelemetryConfig rejects both OTel and Prometheus (T-rt-4)' => sub {
    my $otel = Temporalio::Runtime::OpenTelemetryConfig->new(url => 'http://otel:4317');
    my $prom = Temporalio::Runtime::PrometheusConfig->new(bind_address => '0.0.0.0:9464');

    for my $both ([$otel, $prom], [$prom, $otel]) {
        my $err = exception_from(sub {
            Temporalio::Runtime::TelemetryConfig->new(metrics => $both);
        });
        T2->ok(is_argument_exc($err),
            'both exporters in either order raise Argument')
            or T2->diag("got: " . ($err // 'no exception'));
        T2->like("$err", qr/[Oo]nly one metrics exporter/,
            'message names the only-one-exporter rule');
    }

    # A single exporter is fine in either spelling (bare or one-element list).
    for my $single ($otel, [$otel], $prom, [$prom]) {
        my $cfg = Temporalio::Runtime::TelemetryConfig->new(metrics => $single);
        T2->isa_ok($cfg, 'Temporalio::Runtime::TelemetryConfig');
    }
    T2->is(
        Temporalio::Runtime::TelemetryConfig->new(metrics => [$prom])->metrics,
        $prom,
        'one-element arrayref unwraps to the bare exporter',
    );

    my $junk_err = exception_from(sub {
        Temporalio::Runtime::TelemetryConfig->new(metrics => 'prometheus');
    });
    T2->ok(is_argument_exc($junk_err),
        'a non-config metrics value raises Argument')
        or T2->diag("got: " . ($junk_err // 'no exception'));

    my $default = Temporalio::Runtime::TelemetryConfig->new;
    T2->is($default->metrics, undef, 'metrics defaults to undef');
    T2->isa_ok($default->logging, 'Temporalio::Runtime::LoggingConfig');
    T2->ok($default->attach_service_name, 'attach_service_name defaults true');
});

# --- to_ffi builders (P0.8.3) ----------------------------------------------
# Field-value assertions against temporal-sdk-core-c-bridge.h semantics at
# the pinned tag; struct layout itself is verified by the P0.10 spike.

use FFI::Platypus::Buffer ();

sub read_buffer ($data, $size) {
    return undef unless defined $data;
    return FFI::Platypus::Buffer::buffer_to_scalar($data, $size);
}

# Casts an opaque struct pointer back to a readable record view.
sub record_view ($class, $ptr) {
    return Temporalio::Core::FFI::ffi()->cast('opaque' => "record($class)*", $ptr);
}

T2->subtest('LoggingConfig->to_ffi builds LoggingOptions' => sub {
    my @keep;
    my $config = Temporalio::Runtime::LoggingConfig->new(
        filter => Temporalio::Runtime::LoggingFilter->new(
            core_level  => 'INFO',
            other_level => 'WARN',
        ),
    );
    my $record = $config->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::LoggingOptions');
    T2->is(
        read_buffer($record->filter_data, $record->filter_size),
        $config->filter_string,
        'filter byte array ref points at the filter string',
    );
    T2->is(scalar $record->forward_to, undef,
        'forward_to is NULL (log forwarding deferred past v0.1)');
    T2->ok(scalar @keep, 'backing buffers were pushed onto @keep');
});

T2->subtest('OpenTelemetryConfig->to_ffi builds OpenTelemetryOptions' => sub {
    my @keep;
    my $otel = Temporalio::Runtime::OpenTelemetryConfig->new(
        url                        => 'http://otel:4317',
        headers                    => { authorization => 'Bearer abc', 'x-b' => '2' },
        metric_periodicity         => 60,           # seconds -> 60000 millis
        metric_temporality         => 'delta',
        durations_as_seconds       => 1,
        protocol                   => 'http',
        histogram_bucket_overrides => { my_metric => [0.1, 0.5, 1, 5, 10] },
    );
    my $record = $otel->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::OpenTelemetryOptions');
    T2->is(read_buffer($record->url_data, $record->url_size),
        'http://otel:4317', 'url byte array ref');
    T2->is(
        read_buffer($record->headers_data, $record->headers_size),
        "authorization\nBearer abc\nx-b\n2",
        'headers encoded as the newline-delimited map (sorted keys)',
    );
    T2->is($record->metric_periodicity_millis, 60_000,
        'periodicity converted from seconds to milliseconds');
    T2->is($record->metric_temporality, 2, 'delta maps to enum value 2');
    T2->ok($record->durations_as_seconds, 'durations_as_seconds set');
    T2->is($record->protocol, 2, 'http maps to enum value 2');
    T2->is(
        read_buffer($record->histogram_bucket_overrides_data,
                    $record->histogram_bucket_overrides_size),
        "my_metric\n0.1,0.5,1,5,10",
        'bucket overrides encoded as metric -> comma-joined floats',
    );

    # Defaults: cumulative=1, grpc=1, periodicity 0 = "use core default"
    # (the bridge only reads metric_periodicity_millis when > 0), NULL maps.
    my $default_record = Temporalio::Runtime::OpenTelemetryConfig
        ->new(url => 'http://otel:4317')->to_ffi(\@keep);
    T2->is($default_record->metric_temporality, 1, 'cumulative maps to 1');
    T2->is($default_record->protocol, 1, 'grpc maps to 1');
    T2->is($default_record->metric_periodicity_millis, 0,
        'unset periodicity is 0 (core default)');
    T2->is(scalar $default_record->headers_data, undef, 'unset headers are NULL');
    T2->is($default_record->headers_size, 0, 'unset headers have size 0');
});

T2->subtest('PrometheusConfig->to_ffi builds PrometheusOptions' => sub {
    my @keep;
    my $record = Temporalio::Runtime::PrometheusConfig->new(
        bind_address          => '0.0.0.0:9464',
        counters_total_suffix => 1,
        unit_suffix           => 1,
        durations_as_seconds  => 1,
    )->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::PrometheusOptions');
    T2->is(read_buffer($record->bind_address_data, $record->bind_address_size),
        '0.0.0.0:9464', 'bind_address byte array ref');
    T2->ok($record->counters_total_suffix, 'counters_total_suffix set');
    T2->ok($record->unit_suffix,           'unit_suffix set');
    T2->ok($record->durations_as_seconds,  'durations_as_seconds set');
    T2->is(scalar $record->histogram_bucket_overrides_data, undef,
        'unset overrides are NULL');
});

T2->subtest('TelemetryConfig->to_ffi builds the TelemetryOptions tree' => sub {
    my @keep;
    my $otel = Temporalio::Runtime::OpenTelemetryConfig->new(url => 'http://otel:4317');
    my $record = Temporalio::Runtime::TelemetryConfig->new(
        metrics       => $otel,
        global_tags   => { region => 'us-west-2' },
        metric_prefix => 'custom_',
    )->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::TelemetryOptions');

    T2->ok(defined $record->logging, 'logging pointer is non-NULL');
    my $logging = record_view('Temporalio::Core::FFI::LoggingOptions', $record->logging);
    T2->is(
        read_buffer($logging->filter_data, $logging->filter_size),
        Temporalio::Runtime::LoggingFilter->new->to_string,
        'logging pointer reaches the default filter string',
    );

    T2->ok(defined $record->metrics, 'metrics pointer is non-NULL');
    my $metrics = record_view('Temporalio::Core::FFI::MetricsOptions', $record->metrics);
    T2->ok(defined $metrics->opentelemetry, 'MetricsOptions.opentelemetry set');
    T2->is(scalar $metrics->prometheus,   undef, 'MetricsOptions.prometheus NULL');
    T2->is(scalar $metrics->custom_meter, undef, 'MetricsOptions.custom_meter NULL');
    T2->ok($metrics->attach_service_name, 'attach_service_name defaults true');
    T2->is(
        read_buffer($metrics->global_tags_data, $metrics->global_tags_size),
        "region\nus-west-2",
        'global_tags encoded as the newline-delimited map',
    );
    T2->is(
        read_buffer($metrics->metric_prefix_data, $metrics->metric_prefix_size),
        'custom_',
        'metric_prefix byte array ref',
    );
    my $otel_view = record_view(
        'Temporalio::Core::FFI::OpenTelemetryOptions', $metrics->opentelemetry);
    T2->is(read_buffer($otel_view->url_data, $otel_view->url_size),
        'http://otel:4317', 'opentelemetry pointer reaches the url');

    # Prometheus exporter lands in the prometheus slot instead.
    my $prom_tree = Temporalio::Runtime::TelemetryConfig->new(
        metrics => Temporalio::Runtime::PrometheusConfig->new(
            bind_address => '0.0.0.0:9464'),
    )->to_ffi(\@keep);
    my $prom_metrics =
        record_view('Temporalio::Core::FFI::MetricsOptions', $prom_tree->metrics);
    T2->ok(defined $prom_metrics->prometheus, 'prometheus slot set');
    T2->is(scalar $prom_metrics->opentelemetry, undef, 'opentelemetry slot NULL');

    # No exporter -> metrics NULL (the bridge reads MetricsOptions only to
    # construct an exporter); explicit logging => undef -> logging NULL.
    my $bare = Temporalio::Runtime::TelemetryConfig->new(logging => undef)
        ->to_ffi(\@keep);
    T2->is(scalar $bare->logging, undef, 'logging NULL when explicitly undef');
    T2->is(scalar $bare->metrics, undef, 'metrics NULL when no exporter configured');
});

T2->done_testing;
