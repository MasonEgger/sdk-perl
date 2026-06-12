# ABOUTME: Wraps a *const TemporalCoreByteArray returned from the bridge
# ABOUTME: (spec section 4.3): owns the free path, exposes a Perl scalar.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Scalar::Util ();
use FFI::Platypus::Buffer ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Runtime ();

class Temporalio::Core::ByteArray {
    field $ptr     :param;
    field $runtime :param;
    field $freed = 0;
    field $bytes;    # lazy copy of the contents

    # The runtime reference is weak: the runtime must not be kept alive by
    # outstanding byte arrays, and ->free needs its core pointer only if
    # the runtime still exists (spec section 4.3 failure mode).
    ADJUST { Scalar::Util::weaken($runtime); }

    sub wrap ($class, $ba_ptr, $rt) {
        return $class->new(ptr => $ba_ptr, runtime => $rt);
    }

    method bytes () {
        Temporalio::Exception::Runtime->throw(message => 'ByteArray freed')
            if $freed;
        return $bytes if defined $bytes;
        my $view = Temporalio::Core::FFI::ffi()->cast(
            'opaque' => 'record(Temporalio::Core::FFI::ByteArray)*', $ptr);
        $bytes = FFI::Platypus::Buffer::buffer_to_scalar($view->data, $view->size);
        return $bytes;
    }

    method to_string () { $self->bytes }

    method free () {
        return if $freed;
        $freed = 1;
        if (!defined $runtime) {
            # Runtime shut down before this byte array was freed: the
            # bridge memory leaks, but the runtime that owned the buffer
            # pool is gone anyway. Warn and skip (spec section 4.3).
            warn 'Temporalio::Core::ByteArray: runtime already gone;'
               . " skipping byte array free (memory leaked)\n";
            return;
        }
        Temporalio::Core::FFI::byte_array_free($runtime->core_ptr, $ptr);
        return;
    }

    method DESTROY {
        # During global destruction field/runtime teardown order is
        # undefined; the process is exiting, so leaking is harmless.
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        $self->free;
    }
}

1;

__END__

=head1 NAME

Temporalio::Core::ByteArray - owned wrapper over a bridge-allocated byte array

=head1 SYNOPSIS

    use Temporalio::Core::ByteArray;

    my $ba    = Temporalio::Core::ByteArray->wrap($ptr, $runtime);
    my $bytes = $ba->bytes;       # copies into a Perl scalar (cached)
    my $sv    = $ba->to_string;   # alias for ->bytes
    $ba->free;                    # explicit; idempotent (DESTROY also frees)

=head1 DESCRIPTION

Internal wrapper for C<*const TemporalCoreByteArray> pointers returned from
the sdk-core C bridge. C<bytes> copies the C<data>/C<size> contents into a
Perl scalar via L<FFI::Platypus::Buffer> and caches it; calling it after
C<free> raises L<Temporalio::Exception::Runtime> with message
C<"ByteArray freed">.

C<free> calls C<temporal_core_byte_array_free> with the owning runtime's
core pointer (fetched through a weak reference via C<< $runtime->core_ptr >>)
and is idempotent; C<DESTROY> frees as well. If the runtime was already
destroyed, C<free> warns and skips the bridge call, marking the byte array
freed.

=cut
