# ABOUTME: A custom slot supplier (spec §29.2): wraps a duck-typed impl object
# ABOUTME: whose reserve_slot/try_reserve_slot/mark_slot_used/release_slot
# ABOUTME: methods core invokes via the shim's custom-supplier callbacks. Packs
# ABOUTME: as the Custom union variant (tag 2) carrying a callbacks pointer that
# ABOUTME: the worker binds at build time (NULL until bound).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Exception::Argument ();

# A custom slot supplier. impl is a duck-typed object implementing
# reserve_slot($ctx) (async, returns a permit), try_reserve_slot($ctx)
# (non-blocking, permit-or-undef), mark_slot_used($ctx), release_slot($ctx).
# Core calls these on Tokio threads; the shim parks them on the per-runtime
# queue and the IO::Async loop drains them on the main thread (spec §3 + §29.2).
class Temporalio::Worker::SlotSupplier::Custom {
    field $impl :param;

    # The callbacks pointer core retains. NULL until the worker binds it via
    # _set_callbacks_ptr at WorkerOptions-build time (the shim allocates and
    # @keep-pins the callbacks struct for the worker lifetime).
    field $callbacks_ptr = 0;

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'Custom slot supplier requires an impl object')
            unless defined $impl && ref $impl;
        for my $method (qw(reserve_slot try_reserve_slot mark_slot_used release_slot)) {
            Temporalio::Exception::Argument->throw(
                message => "Custom slot supplier impl must implement $method")
                unless $impl->can($method);
        }
    }

    method impl { $impl }

    # The worker binds the shim-allocated callbacks pointer here once it has
    # registered this supplier with the per-runtime custom-supplier registry.
    method _set_callbacks_ptr ($ptr) { $callbacks_ptr = $ptr; return; }
    method _callbacks_ptr { $callbacks_ptr }

    # _pack_spec -> { custom => $callbacks_ptr }. Packed as the Custom union
    # variant (tag 2); the body is the single pointer core retains.
    method _pack_spec { return { custom => $callbacks_ptr } }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Worker::SlotSupplier::Custom - custom worker slot supplier

=head1 SYNOPSIS

    my $supplier = Temporalio::Worker::SlotSupplier::Custom->new(impl => $my_impl);

=head1 DESCRIPTION

Wraps a duck-typed C<impl> object (spec §29.2). Core invokes the impl's
C<reserve_slot> / C<try_reserve_slot> / C<mark_slot_used> / C<release_slot>
methods through the bridge shim, which parks each call on the per-runtime queue
so the Perl method runs on the main thread (never on a core/Tokio thread).

=head1 METHODS

=head2 impl

The wrapped duck-typed supplier implementation object.

=cut
