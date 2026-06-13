# ABOUTME: Wraps a TemporalCoreCancellationToken (spec section 4.4) for
# ABOUTME: client-side RPC cancellation and worker-side cancel propagation.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Temporalio::Core::FFI ();

class Temporalio::Cancellation {
    field $ptr;
    field $cancelled = 0;    # Perl-side flag: is_cancelled never hits FFI
    field $future;           # shared Future, created lazily by ->cancelled

    ADJUST {
        $ptr = Temporalio::Core::FFI::cancellation_token_new();
    }

    # The raw TemporalCoreCancellationToken pointer, for internal callers
    # that fill C structs (e.g. TemporalCoreRpcCallOptions.cancellation_token).
    method core_ptr () { $ptr }

    method is_cancelled () { $cancelled ? 1 : 0 }

    method cancel () {
        return if $cancelled;
        $cancelled = 1;
        Temporalio::Core::FFI::cancellation_token_cancel($ptr);
        $future->done if defined $future && !$future->is_ready;
        return;
    }

    method cancelled () {
        $future //= $cancelled ? Future->done : Future->new;
        return $future;
    }

    method DESTROY {
        # During global destruction teardown order is undefined; the process
        # is exiting, so leaking the token is harmless (same policy as
        # Temporalio::Core::ByteArray).
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        Temporalio::Core::FFI::cancellation_token_free($ptr) if defined $ptr;
        $ptr = undef;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Cancellation - cancellation token over TemporalCoreCancellationToken

=head1 SYNOPSIS

    use Temporalio::Cancellation;

    my $token = Temporalio::Cancellation->new;

    my $f = $token->cancelled;     # Future that resolves when cancelled
    $token->cancel;                # idempotent
    my $is_cancelled = $token->is_cancelled;

=head1 DESCRIPTION

Wraps a C<TemporalCoreCancellationToken> from the sdk-core C bridge for
client-side cancellation of long-running RPCs and worker-side cancellation
propagation (spec section 4.4). All operations are infallible after
construction.

=head1 METHODS

=head2 cancel

Cancels the underlying core token (once; repeated calls are no-ops), sets
the Perl-side cancelled flag, and resolves the L</cancelled> Future if one
has been handed out.

=head2 is_cancelled

Returns the Perl-side flag — cheap, no FFI call.

=head2 cancelled

Returns a L<Future> that resolves when the token is cancelled. If the token
is already cancelled, returns an already-resolved Future. The same Future
instance is shared across calls.

=head2 core_ptr

The raw C<TemporalCoreCancellationToken> pointer, for internal code filling
bridge structs that carry a cancellation token.

=head1 DESTRUCTION

C<DESTROY> frees the core token via C<temporal_core_cancellation_token_free>
(skipped during global destruction, where teardown order is undefined and
the process is exiting anyway).

=head1 CONSTRUCTOR

=head2 new

Constructs a Temporalio::Cancellation.

=cut
