# ABOUTME: Prometheus metrics exporter configuration (spec section 4.2);
# ABOUTME: builds the PrometheusOptions record for the core runtime.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::FFI ();

class Temporalio::Runtime::PrometheusConfig {
    field $bind_address               :param;
    field $counters_total_suffix      :param = 0;
    field $unit_suffix                :param = 0;
    field $durations_as_seconds       :param = 0;
    field $histogram_bucket_overrides :param = undef;   # { metric => [floats] }

    method bind_address               { $bind_address }
    method counters_total_suffix      { $counters_total_suffix }
    method unit_suffix                { $unit_suffix }
    method durations_as_seconds       { $durations_as_seconds }
    method histogram_bucket_overrides { $histogram_bucket_overrides }

    # Builds a TemporalCorePrometheusOptions record; buffers backing the
    # record's pointers are pushed onto @$keep.
    method to_ffi ($keep) {
        my ($addr_data, $addr_size) =
            Temporalio::Core::FFI::keep_buffer($keep, $bind_address);
        my ($overrides_data, $overrides_size) = Temporalio::Core::FFI::keep_buffer(
            $keep, Temporalio::Core::FFI::encode_bucket_overrides($histogram_bucket_overrides));
        return Temporalio::Core::FFI::PrometheusOptions->new(
            bind_address_data               => $addr_data,
            bind_address_size               => $addr_size,
            counters_total_suffix           => $counters_total_suffix ? 1 : 0,
            unit_suffix                     => $unit_suffix ? 1 : 0,
            durations_as_seconds            => $durations_as_seconds ? 1 : 0,
            histogram_bucket_overrides_data => $overrides_data,
            histogram_bucket_overrides_size => $overrides_size,
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Runtime::PrometheusConfig - Prometheus metrics exporter options

=head1 SYNOPSIS

    use Temporalio::Runtime::PrometheusConfig;

    my $prom = Temporalio::Runtime::PrometheusConfig->new(
        bind_address               => '0.0.0.0:9464',
        counters_total_suffix      => 0,
        unit_suffix                => 0,
        durations_as_seconds       => 0,
        histogram_bucket_overrides => { my_metric => [0.1, 0.5, 1, 5, 10] },
    );

=head1 DESCRIPTION

Metrics exporter configuration for a Prometheus scrape endpoint (spec
section 4.2). All suffix/seconds flags default to false, matching the
reference SDKs. C<to_ffi(\@keep)> produces the
C<TemporalCorePrometheusOptions> record; backing buffers are pushed onto
C<@keep> and must outlive any use of the record.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Runtime::PrometheusConfig->new(
        bind_address => ...,
        counters_total_suffix => ...,
        unit_suffix => ...,
        durations_as_seconds => ...,
        histogram_bucket_overrides => ...,
    );

Constructs a Temporalio::Runtime::PrometheusConfig. Named parameters:

=over 4

=item C<bind_address>

(required)

=item C<counters_total_suffix>

(optional, default C<0>)

=item C<unit_suffix>

(optional, default C<0>)

=item C<durations_as_seconds>

(optional, default C<0>)

=item C<histogram_bucket_overrides>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 bind_address

Accessor returning the C<bind_address> value.

=head2 counters_total_suffix

Accessor returning the C<counters_total_suffix> value.

=head2 durations_as_seconds

Accessor returning the C<durations_as_seconds> value.

=head2 histogram_bucket_overrides

Accessor returning the C<histogram_bucket_overrides> value.

=head2 to_ffi

Returns the FFI Prometheus-options record for this config.

=head2 unit_suffix

Accessor returning the C<unit_suffix> value.

=cut
