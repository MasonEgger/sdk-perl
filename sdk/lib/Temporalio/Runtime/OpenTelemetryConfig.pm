# ABOUTME: OpenTelemetry metrics exporter configuration (spec section 4.2);
# ABOUTME: validates temporality/protocol and builds the OpenTelemetryOptions record.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use FFI::Platypus::Buffer ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();

class Temporalio::Runtime::OpenTelemetryConfig {
    field $url                        :param;
    field $headers                    :param = undef;   # hashref or undef
    field $metric_periodicity         :param = undef;   # seconds; undef = core default
    field $metric_temporality         :param = 'cumulative';
    field $durations_as_seconds       :param = 0;
    field $protocol                   :param = 'grpc';
    field $histogram_bucket_overrides :param = undef;   # { metric => [floats] }

    # Enum values MUST match temporal-sdk-core-c-bridge.h at the pinned tag:
    # TemporalCoreOpenTelemetryMetricTemporality { Cumulative = 1, Delta = 2 }
    # TemporalCoreOpenTelemetryProtocol          { Grpc = 1, Http = 2 }
    my %temporality_value = (cumulative => 1, delta => 2);
    my %protocol_value    = (grpc => 1, http => 2);

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => "metric_temporality must be 'cumulative' or 'delta'"
                     . " (got '" . ($metric_temporality // 'undef') . "')",
        ) unless defined $metric_temporality
              && $temporality_value{$metric_temporality};
        Temporalio::Exception::Argument->throw(
            message => "protocol must be 'grpc' or 'http'"
                     . " (got '" . ($protocol // 'undef') . "')",
        ) unless defined $protocol && $protocol_value{$protocol};
    }

    method url                        { $url }
    method headers                    { $headers }
    method metric_periodicity         { $metric_periodicity }
    method metric_temporality         { $metric_temporality }
    method durations_as_seconds       { $durations_as_seconds }
    method protocol                   { $protocol }
    method histogram_bucket_overrides { $histogram_bucket_overrides }

    # Builds a TemporalCoreOpenTelemetryOptions record. Buffers backing the
    # record's pointers are pushed onto @$keep (caller must hold them for the
    # record's useful life). The bridge treats metric_periodicity_millis == 0
    # as "use the core default" (verified in sdk-core-c-bridge runtime.rs).
    method to_ffi ($keep) {
        my ($url_data, $url_size) = Temporalio::Core::FFI::keep_buffer($keep, $url);
        my ($headers_data, $headers_size) = Temporalio::Core::FFI::keep_buffer(
            $keep, Temporalio::Core::FFI::encode_newline_map($headers));
        my ($overrides_data, $overrides_size) = Temporalio::Core::FFI::keep_buffer(
            $keep, Temporalio::Core::FFI::encode_bucket_overrides($histogram_bucket_overrides));
        return Temporalio::Core::FFI::OpenTelemetryOptions->new(
            url_data                        => $url_data,
            url_size                        => $url_size,
            headers_data                    => $headers_data,
            headers_size                    => $headers_size,
            metric_periodicity_millis       =>
                defined $metric_periodicity ? int($metric_periodicity * 1000) : 0,
            metric_temporality              => $temporality_value{$metric_temporality},
            durations_as_seconds            => $durations_as_seconds ? 1 : 0,
            protocol                        => $protocol_value{$protocol},
            histogram_bucket_overrides_data => $overrides_data,
            histogram_bucket_overrides_size => $overrides_size,
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Runtime::OpenTelemetryConfig - OpenTelemetry metrics exporter options

=head1 SYNOPSIS

    use Temporalio::Runtime::OpenTelemetryConfig;

    my $otel = Temporalio::Runtime::OpenTelemetryConfig->new(
        url                        => 'http://otel:4317',
        headers                    => { authorization => 'Bearer ...' },
        metric_periodicity         => 60,                # seconds
        metric_temporality         => 'cumulative',      # or 'delta'
        durations_as_seconds       => 0,
        protocol                   => 'grpc',            # or 'http'
        histogram_bucket_overrides => { my_metric => [0.1, 0.5, 1, 5, 10] },
    );

=head1 DESCRIPTION

Metrics exporter configuration for OpenTelemetry (spec section 4.2). Invalid
C<metric_temporality> or C<protocol> strings raise
L<Temporalio::Exception::Argument>. C<to_ffi(\@keep)> produces the
C<TemporalCoreOpenTelemetryOptions> record with enum values matching the
pinned C header (cumulative=1/delta=2, grpc=1/http=2), seconds converted to
milliseconds, and headers/overrides encoded as newline-delimited maps;
backing buffers are pushed onto C<@keep>.

=cut
