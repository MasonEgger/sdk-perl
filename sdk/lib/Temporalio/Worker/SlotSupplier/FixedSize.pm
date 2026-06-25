# ABOUTME: A fixed-size slot supplier (spec §29.2): never issues more than
# ABOUTME: num_slots concurrent slots for its pool. Packs as the FixedSize union
# ABOUTME: variant (tag 0) carrying a single uintptr_t.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

# A fixed-size slot supplier. num_slots is the maximum concurrent slots; it must
# be a positive integer (sdk-python FixedSizeSlotSupplier, sdk-ruby tuner.rb).
class Temporalio::Worker::SlotSupplier::FixedSize {
    field $num_slots :param;

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'FixedSize num_slots must be a positive integer')
            unless defined $num_slots
                && $num_slots =~ /\A[0-9]+\z/
                && $num_slots > 0;
    }

    method num_slots { $num_slots }

    # _pack_spec -> the hash Temporalio::Core::FFI::WorkerOptions::pack_slot_supplier
    # consumes: { fixed_size => $num_slots }.
    method _pack_spec { return { fixed_size => $num_slots } }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::SlotSupplier::FixedSize - fixed-size worker slot supplier

=head1 SYNOPSIS

    my $supplier = Temporalio::Worker::SlotSupplier::FixedSize->new(num_slots => 100);

=head1 DESCRIPTION

Issues at most C<num_slots> concurrent slots for its pool (spec §29.2). This is
the v0.1-parity default supplier used when a worker is configured with the
legacy C<max_concurrent_*> kwargs.

=head1 METHODS

=head2 num_slots

The maximum number of concurrent slots for this pool.

=cut
