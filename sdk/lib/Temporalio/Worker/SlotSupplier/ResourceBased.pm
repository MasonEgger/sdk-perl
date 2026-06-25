# ABOUTME: A resource-based slot supplier (spec §29.2): adjusts slot count to
# ABOUTME: keep system memory/CPU near the targets. Packs as the ResourceBased
# ABOUTME: union variant (tag 1) carrying min/max slots, ramp throttle, and the
# ABOUTME: target memory/CPU tuner options.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use Temporalio::Exception::Argument ();

# A resource-based slot supplier. target_memory_usage / target_cpu_usage are
# fractions in (0, 1] (sdk-python ResourceBasedTunerConfig; values > 0.8 memory
# are discouraged but allowed). minimum_slots/maximum_slots bound the dynamic
# range; ramp_throttle_ms is the minimum wait between handing out new slots.
class Temporalio::Worker::SlotSupplier::ResourceBased {
    field $target_memory_usage :param;
    field $target_cpu_usage    :param;
    field $minimum_slots       :param = 1;
    field $maximum_slots       :param = 500;
    field $ramp_throttle_ms    :param = 0;

    ADJUST {
        _assert_target('target_memory_usage', $target_memory_usage);
        _assert_target('target_cpu_usage',    $target_cpu_usage);
        Temporalio::Exception::Argument->throw(
            message => 'minimum_slots must be a non-negative integer')
            unless _is_uint($minimum_slots);
        Temporalio::Exception::Argument->throw(
            message => 'maximum_slots must be a positive integer')
            unless _is_uint($maximum_slots) && $maximum_slots > 0;
        Temporalio::Exception::Argument->throw(
            message => 'minimum_slots must not exceed maximum_slots')
            if $minimum_slots > $maximum_slots;
        Temporalio::Exception::Argument->throw(
            message => 'ramp_throttle_ms must be a non-negative integer')
            unless _is_uint($ramp_throttle_ms);
    }

    # A target must be a number in (0, 1]; 0 and values above 1 are rejected
    # (the underlying controller treats the target as a fraction of system use).
    sub _assert_target ($name, $value) {
        Temporalio::Exception::Argument->throw(
            message => "$name must be a number in (0, 1]")
            unless defined $value
                && Scalar::Util::looks_like_number($value)
                && $value > 0
                && $value <= 1;
        return;
    }

    sub _is_uint ($value) {
        return defined $value && $value =~ /\A[0-9]+\z/;
    }

    method target_memory_usage { $target_memory_usage }
    method target_cpu_usage    { $target_cpu_usage }
    method minimum_slots       { $minimum_slots }
    method maximum_slots       { $maximum_slots }
    method ramp_throttle_ms    { $ramp_throttle_ms }

    # _pack_spec -> the hash pack_slot_supplier consumes:
    #   { resource_based => { minimum_slots, maximum_slots, ramp_throttle_ms,
    #                         target_memory_usage, target_cpu_usage } }.
    method _pack_spec {
        return {
            resource_based => {
                minimum_slots       => $minimum_slots,
                maximum_slots       => $maximum_slots,
                ramp_throttle_ms    => $ramp_throttle_ms,
                target_memory_usage => $target_memory_usage,
                target_cpu_usage    => $target_cpu_usage,
            },
        };
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::SlotSupplier::ResourceBased - resource-based worker slot supplier

=head1 SYNOPSIS

    my $supplier = Temporalio::Worker::SlotSupplier::ResourceBased->new(
        target_memory_usage => 0.8,
        target_cpu_usage     => 0.9,
        minimum_slots        => 1,
        maximum_slots        => 500,
        ramp_throttle_ms     => 0,
    );

=head1 DESCRIPTION

Dynamically adjusts the number of slots based on system resource usage (spec
§29.2). The memory and CPU targets are fractions in C<(0, 1]>.

=head1 METHODS

=head2 target_memory_usage

The target system memory usage fraction in C<(0, 1]>.

=head2 target_cpu_usage

The target system CPU usage fraction in C<(0, 1]>.

=head2 minimum_slots

The minimum number of slots always issued.

=head2 maximum_slots

The maximum number of slots permitted.

=head2 ramp_throttle_ms

The minimum wait (milliseconds) between handing out new slots.

=cut
