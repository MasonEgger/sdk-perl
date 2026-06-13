# ABOUTME: Owns a live TemporalCoreConnection pointer (spec section 7.3):
# ABOUTME: api-key rotation via the bridge, explicit close, free-on-reclaim.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Runtime ();

class Temporalio::Client::Connection {
    field $runtime :param;    # Temporalio::Runtime (must outlive us)
    field $ptr     :param;    # TemporalCoreConnection*
    field $is_closed = 0;

    method _assert_open () {
        Temporalio::Exception::Runtime->throw(
            message => 'Connection is closed')
            if $is_closed;
        return;
    }

    method ptr ()       { $self->_assert_open; $ptr }
    method runtime ()   { $runtime }
    method is_closed () { $is_closed }

    # Rotate the bearer token on the live connection (spec section 7.3):
    # synchronous, no RPC, manual and explicit — there is no automatic
    # refresh timer and no refresh-on-UNAUTHENTICATED.
    method update_api_key ($api_key) {
        $self->_assert_open;
        Temporalio::Exception::Argument->throw(
            message => 'update_api_key requires a defined token')
            unless defined $api_key;
        # The bridge copies the token during the call; @keep pins the
        # buffer until then.
        my @keep;
        my ($data, $size) = Temporalio::Core::FFI::keep_buffer(\@keep, $api_key);
        my $key_ref = Temporalio::Core::FFI::ByteArrayRef->new(
            data => $data,
            size => $size,
        );
        Temporalio::Core::FFI::client_update_api_key($ptr, $key_ref);
        return;
    }

    # Idempotent. The runtime must still be open: client_free drops the
    # core connection on the runtime's Tokio threads.
    method close () {
        return if $is_closed;
        $is_closed = 1;
        Temporalio::Core::FFI::client_free($ptr) if defined $ptr;
        $ptr = undef;
        return;
    }

    method DESTROY {
        # During global destruction field teardown order is undefined and
        # the process is exiting anyway; skip (same guard as Runtime).
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        return if $is_closed;
        warn 'Temporalio::Client::Connection: connection reclaimed without'
           . " close; freeing in DESTROY (call ->close explicitly)\n";
        $self->close;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Client::Connection - live connection handle to a Temporal server

=head1 SYNOPSIS

    # Constructed by Temporalio::Client->connect; not user-built.
    my $connection = $client->connection;

    $connection->update_api_key($new_token);
    $connection->close;    # idempotent; frees the C connection

=head1 DESCRIPTION

Holds the C<TemporalCoreConnection> pointer produced by
C<temporal_core_client_connect> (spec section 7.3). The owning
L<Temporalio::Runtime> must outlive the connection. C<update_api_key>
rotates the bearer token via C<temporal_core_client_update_api_key> —
synchronous, no RPC, and never automatic. C<close> frees the C connection
via C<temporal_core_client_free> and is idempotent; afterwards C<ptr> and
C<update_api_key> raise L<Temporalio::Exception::Runtime> with
C<"Connection is closed">. C<DESTROY> frees with a warning — call
C<close> explicitly.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Client::Connection->new(
        runtime => ...,
        ptr => ...,
    );

Constructs a Temporalio::Client::Connection. Named parameters:

=over 4

=item C<runtime>

(required)

=item C<ptr>

(required)

=back

=head1 METHODS

=head2 close

Closes the underlying sdk-core connection and frees its C pointer.

=head2 is_closed

Accessor returning the C<is_closed> value.

=head2 ptr

Returns the raw C<TemporalCoreConnection*> pointer (for FFI calls). Internal.

=head2 runtime

Accessor returning the C<runtime> value.

=head2 update_api_key

Updates the API key applied to subsequent RPCs on this connection.

=cut
