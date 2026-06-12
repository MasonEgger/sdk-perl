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

class Temporalio::Runtime::TelemetryConfig {
    # metrics accepts undef, one exporter config, or an arrayref of exporter
    # configs. More than one exporter — e.g. both OpenTelemetry and
    # Prometheus — raises Argument (T-rt-4): the C bridge's MetricsOptions
    # allows only one of opentelemetry/prometheus to be present.
    # NOTE: no MetricBuffer — the C bridge has no buffered-metrics API; custom
    # metric meters are deferred (spec section 15).
    field $logging             :param = Temporalio::Runtime::LoggingConfig->default;
    field $metrics             :param = undef;
    field $global_tags         :param = undef;   # hashref or undef
    field $attach_service_name :param = 1;
    field $metric_prefix       :param = undef;

    my @exporter_classes = qw(
        Temporalio::Runtime::OpenTelemetryConfig
        Temporalio::Runtime::PrometheusConfig
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
                         . ' (OpenTelemetry OR Prometheus, not both)',
            );
        }
        for my $exporter (@exporters) {
            next if _is_exporter($exporter);
            Temporalio::Exception::Argument->throw(
                message => 'metrics must be a Temporalio::Runtime::OpenTelemetryConfig'
                         . ' or Temporalio::Runtime::PrometheusConfig instance',
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
            my $exporter_ptr =
                Temporalio::Core::FFI::keep_record($keep, $metrics->to_ffi($keep));
            my $is_otel =
                $metrics->isa('Temporalio::Runtime::OpenTelemetryConfig');
            my ($tags_data, $tags_size) = Temporalio::Core::FFI::keep_buffer(
                $keep, Temporalio::Core::FFI::encode_newline_map($global_tags));
            my ($prefix_data, $prefix_size) =
                Temporalio::Core::FFI::keep_buffer($keep, $metric_prefix);
            my $metrics_record = Temporalio::Core::FFI::MetricsOptions->new(
                opentelemetry       => $is_otel ? $exporter_ptr : undef,
                prometheus          => $is_otel ? undef : $exporter_ptr,
                custom_meter        => undef,
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

=cut
