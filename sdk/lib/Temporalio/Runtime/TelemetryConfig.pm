# ABOUTME: Top-level telemetry configuration for the core runtime (spec
# ABOUTME: section 4.2): logging plus at most one metrics exporter (T-rt-4).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Runtime::LoggingConfig ();
use Temporalio::Runtime::MetricMeter ();

class Temporalio::Runtime::TelemetryConfig {
    # metrics accepts undef, one exporter, or an arrayref of exporters. More
    # than one — e.g. both OpenTelemetry and Prometheus, or an exporter plus a
    # custom meter — raises Argument (T-rt-4 / T-meter-2): the C bridge's
    # MetricsOptions allows only one of opentelemetry/prometheus/custom_meter.
    # A custom meter is a Temporalio::Runtime::MetricMeter (spec section 28.2);
    # the Python MetricBuffer pull model is not implementable (the pinned C
    # header has no buffered_with_size, only custom_meter).
    field $logging             :param = Temporalio::Runtime::LoggingConfig->default;
    field $metrics             :param = undef;
    field $global_tags         :param = undef;   # hashref or undef
    field $attach_service_name :param = 1;
    field $metric_prefix       :param = undef;

    my @exporter_classes = qw(
        Temporalio::Runtime::OpenTelemetryConfig
        Temporalio::Runtime::PrometheusConfig
        Temporalio::Runtime::MetricMeter
    );

    sub _is_exporter ($value) {
        return Scalar::Util::blessed($value)
            && grep { $value->isa($_) } @exporter_classes;
    }

    ADJUST {
        my @exporters =
              !defined $metrics          ? ()
            : ref $metrics eq 'ARRAY'    ? @$metrics
            :                              ($metrics);
        if (@exporters > 1) {
            Temporalio::Exception::Argument->throw(
                message => 'Only one metrics exporter may be configured'
                         . ' (OpenTelemetry, Prometheus, or a custom'
                         . ' MetricMeter — not more than one)',
            );
        }
        for my $exporter (@exporters) {
            next if _is_exporter($exporter);
            Temporalio::Exception::Argument->throw(
                message => 'metrics must be a Temporalio::Runtime::OpenTelemetryConfig,'
                         . ' Temporalio::Runtime::PrometheusConfig, or'
                         . ' Temporalio::Runtime::MetricMeter instance',
            );
        }
        $metrics = @exporters ? $exporters[0] : undef;

        if (defined $logging
            && !(Scalar::Util::blessed($logging)
                 && $logging->isa('Temporalio::Runtime::LoggingConfig'))) {
            Temporalio::Exception::Argument->throw(
                message => 'logging must be a Temporalio::Runtime::LoggingConfig'
                         . ' instance or undef',
            );
        }
    }

    method logging             { $logging }
    method metrics             { $metrics }
    method global_tags         { $global_tags }
    method attach_service_name { $attach_service_name }
    method metric_prefix       { $metric_prefix }

    # The custom MetricMeter if one is configured, else undef. Temporalio::Runtime
    # uses this to claim the process-global meter registry (spec section 28.2).
    method custom_meter () {
        return (defined $metrics
            && $metrics->isa('Temporalio::Runtime::MetricMeter')) ? $metrics : undef;
    }

    # Builds the TemporalCoreTelemetryOptions record tree: pointers to a
    # LoggingOptions record (NULL if logging is undef) and a MetricsOptions
    # record (NULL unless a metrics exporter is configured — the C bridge
    # only reads MetricsOptions to build an exporter). Every nested record
    # and backing buffer is pushed onto @$keep; the caller must hold @$keep
    # alive for as long as the returned record may be dereferenced.
    method to_ffi ($keep) {
        my $logging_ptr = defined $logging
            ? Temporalio::Core::FFI::keep_record($keep, $logging->to_ffi($keep))
            : undef;

        my $metrics_ptr;
        if (defined $metrics) {
            my ($otel_ptr, $prom_ptr, $meter_ptr);
            if ($metrics->isa('Temporalio::Runtime::MetricMeter')) {
                # custom_meter: pack the shim's eight callback pointers into a
                # TemporalCoreCustomMetricMeter the bridge stores. Routing the
                # callbacks to this $metrics object (and freeing it) is the
                # process-global registry's job, set up by Temporalio::Runtime.
                my @ptr = Temporalio::Core::FFI::meter_callback_ptrs();
                my $meter_record = Temporalio::Core::FFI::CustomMetricMeter->new(
                    metric_new             => $ptr[0],
                    metric_free            => $ptr[1],
                    metric_record_integer  => $ptr[2],
                    metric_record_float    => $ptr[3],
                    metric_record_duration => $ptr[4],
                    attributes_new         => $ptr[5],
                    attributes_free        => $ptr[6],
                    meter_free             => $ptr[7],
                );
                $meter_ptr =
                    Temporalio::Core::FFI::keep_record($keep, $meter_record);
            }
            elsif ($metrics->isa('Temporalio::Runtime::OpenTelemetryConfig')) {
                $otel_ptr =
                    Temporalio::Core::FFI::keep_record($keep, $metrics->to_ffi($keep));
            }
            else {
                $prom_ptr =
                    Temporalio::Core::FFI::keep_record($keep, $metrics->to_ffi($keep));
            }
            my ($tags_data, $tags_size) = Temporalio::Core::FFI::keep_buffer(
                $keep, Temporalio::Core::FFI::encode_newline_map($global_tags));
            my ($prefix_data, $prefix_size) =
                Temporalio::Core::FFI::keep_buffer($keep, $metric_prefix);
            my $metrics_record = Temporalio::Core::FFI::MetricsOptions->new(
                opentelemetry       => $otel_ptr,
                prometheus          => $prom_ptr,
                custom_meter        => $meter_ptr,
                attach_service_name => $attach_service_name ? 1 : 0,
                global_tags_data    => $tags_data,
                global_tags_size    => $tags_size,
                metric_prefix_data  => $prefix_data,
                metric_prefix_size  => $prefix_size,
            );
            $metrics_ptr = Temporalio::Core::FFI::keep_record($keep, $metrics_record);
        }

        return Temporalio::Core::FFI::TelemetryOptions->new(
            logging => $logging_ptr,
            metrics => $metrics_ptr,
        );
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Runtime::TelemetryConfig - telemetry configuration for the core runtime

=head1 SYNOPSIS

    use Temporalio::Runtime::TelemetryConfig;

    my $telemetry = Temporalio::Runtime::TelemetryConfig->new(
        logging             => Temporalio::Runtime::LoggingConfig->default,
        metrics             => $otel_or_prometheus_config,   # or undef
        global_tags         => { region => 'us-west-2' },
        attach_service_name => 1,
        metric_prefix       => undef,
    );

=head1 DESCRIPTION

Top-level telemetry options passed to L<Temporalio::Runtime> (spec section
4.2). C<metrics> accepts C<undef>, a single
L<Temporalio::Runtime::OpenTelemetryConfig> or
L<Temporalio::Runtime::PrometheusConfig>, or an arrayref of exporter
configs; supplying more than one exporter raises
L<Temporalio::Exception::Argument> (T-rt-4), because the C bridge accepts
only one of OpenTelemetry/Prometheus. C<to_ffi(\@keep)> builds the
C<TemporalCoreTelemetryOptions> record tree (logging and metrics records by
pointer), pushing every nested record and backing buffer onto C<@keep>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Runtime::TelemetryConfig->new(
        logging => ...,
        metrics => ...,
        global_tags => ...,
        attach_service_name => ...,
        metric_prefix => ...,
    );

Constructs a Temporalio::Runtime::TelemetryConfig. Named parameters:

=over 4

=item C<logging>

(optional, default C<Temporalio::Runtime::LoggingConfig->default>)

=item C<metrics>

(optional, default C<undef>)

=item C<global_tags>

(optional, default C<undef>)

=item C<attach_service_name>

(optional, default C<1>)

=item C<metric_prefix>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 attach_service_name

Accessor returning the C<attach_service_name> value.

=head2 custom_meter

Returns the configured L<Temporalio::Runtime::MetricMeter> when C<metrics> is a
custom meter (spec section 28.2), or C<undef> otherwise.
L<Temporalio::Runtime> uses this to claim the process-global meter registry.

=head2 global_tags

Accessor returning the C<global_tags> value.

=head2 logging

Accessor returning the C<logging> value.

=head2 metric_prefix

Accessor returning the C<metric_prefix> value.

=head2 metrics

Accessor returning the C<metrics> value.

=head2 to_ffi

Returns the FFI telemetry-options record aggregating logging and metrics for this config.

=cut
