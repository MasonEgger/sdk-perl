# ABOUTME: Owns a live TemporalCoreConnection pointer (spec section 7.3):
# ABOUTME: api-key rotation via the bridge, explicit close, free-on-reclaim,
# ABOUTME: and the deferred (lazy) connect shared by concurrent first RPCs.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Runtime ();

class Temporalio::Client::Connection {
    field $runtime :param;          # Temporalio::Runtime (must outlive us)
    field $ptr     :param = undef;  # TemporalCoreConnection* (undef until the
                                    # deferred connect completes when lazy)
    field $connect :param = undef;  # async coderef () -> ptr; the deferred
                                    # core connect of a lazy client (spec R90)
    field $connect_future;          # once-init guard: the single in-flight
                                    # connect shared by concurrent first RPCs
    field $is_closed = 0;

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'Connection requires either a live ptr or a deferred'
                     . ' connect coderef')
            unless defined $ptr || defined $connect;
    }

    method _assert_open () {
        Temporalio::Exception::Runtime->throw(
            message => 'Connection is closed')
            if $is_closed;
        return;
    }

    method ptr () {
        $self->_assert_open;
        # A lazy client that has not made an RPC yet has no pointer to hand
        # out; this is also what stops a Worker from being built on an
        # unconnected lazy client (sdk-python raises "Lazy clients cannot be
        # used for workers" for the same reason).
        Temporalio::Exception::Runtime->throw(
            message => 'Connection is not yet established (lazy client):'
                     . ' the first RPC connects, and a worker cannot be'
                     . ' built on an unconnected lazy client')
            unless defined $ptr;
        return $ptr;
    }

    # connected_ptr — async. Resolves to the live TemporalCoreConnection
    # pointer, performing the deferred (lazy) connect on first use (spec R90,
    # parity audit client finding 3; sdk-python service.py
    # _BridgeServiceClient._connected_client / _client.py:151,205-207).
    # Once-init guard: concurrent first RPCs all await the single in-flight
    # connect future instead of racing their own core connects. A failed
    # connect clears the guard so the next RPC retries, exactly like
    # Python's lock-guarded "if not self._bridge_client" re-check.
    async method connected_ptr () {
        $self->_assert_open;
        return $ptr if defined $ptr;
        Temporalio::Exception::Runtime->throw(
            message => 'Connection has no pointer and no deferred connect')
            unless defined $connect;

        my $in_flight = $connect_future;
        if (!defined $in_flight) {
            # $connect is an async sub, so Future->call always gets a Future
            # back and routes a synchronous die into a failed Future.
            $in_flight      = Future->call($connect);
            $connect_future = $in_flight;
            $in_flight->on_done(sub ($p) {
                if ($is_closed) {
                    # Closed while the connect was in flight: nothing can
                    # hand this pointer out any more, so free it now (same
                    # liveness guard as _free_client).
                    Temporalio::Core::FFI::client_free($p)
                        if defined $p && defined $runtime
                        && !$runtime->is_shutdown;
                }
                else {
                    $ptr     = $p;
                    $connect = undef;    # release the captured connect state
                }
                undef $connect_future;
            });
            $in_flight->on_fail(sub { undef $connect_future });
        }
        my $p = await $in_flight;
        # Closed while we were parked on the connect: the on_done above
        # already freed the pointer, so surface the close instead.
        $self->_assert_open;
        return $p;
    }

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
        # The bridge rotation needs a live connection; a lazy client that has
        # not connected yet has none. Fail loud instead of dropping the token
        # (the connect options captured at connect() time carry the original
        # api_key) — make an RPC first, then rotate.
        Temporalio::Exception::Runtime->throw(
            message => 'update_api_key requires an established connection'
                     . ' (lazy client: make an RPC first)')
            unless defined $ptr;
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

    # Liveness-guarded free (finding L2 / spec R2). client_free drops the
    # core connection on the runtime's Tokio threads; once Runtime->shutdown
    # has torn the core runtime down, that call is a use-after-free. When
    # the runtime is gone we release only Perl-side state and skip the FFI
    # free. Both close and DESTROY (via close) route through this one
    # method so the guard cannot drift between the two paths.
    method _free_client () {
        Temporalio::Core::FFI::client_free($ptr)
            if defined $ptr && defined $runtime && !$runtime->is_shutdown;
        $ptr = undef;
        return;
    }

    # Idempotent. Frees the C connection only while the owning runtime is
    # still live (see _free_client above).
    method close () {
        return if $is_closed;
        $is_closed = 1;
        $self->_free_client;
        return;
    }

    method DESTROY {
        # During global destruction field teardown order is undefined and
        # the process is exiting anyway; skip (same guard as Runtime).
        return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
        return if $is_closed;
        # A lazy connection that never connected holds no C pointer: nothing
        # to free, nothing to warn about.
        if (!defined $ptr) {
            $is_closed = 1;
            return;
        }
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

A lazy client (spec R90; C<< Temporalio::Client->connect(lazy => 1) >>)
constructs the connection with a deferred C<connect> coderef instead of a
pointer. C<connected_ptr> performs that core connect on first use behind a
once-init guard, so concurrent first RPCs share the single in-flight
connect; a failed connect clears the guard and the next RPC retries.
Until it has connected, C<ptr> and C<update_api_key> raise
L<Temporalio::Exception::Runtime>.

Both C<close> and C<DESTROY> guard the FFI free with a runtime-liveness
check: C<temporal_core_client_free> drops the core connection on the
runtime's Tokio threads, so once the runtime has shut down the free is
skipped and only Perl-side state is released (finding L2).

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Client::Connection->new(
        runtime => ...,
        ptr => ...,        # or connect => ..., for a lazy client
    );

Constructs a Temporalio::Client::Connection. Named parameters:

=over 4

=item C<runtime>

(required)

=item C<ptr>

(optional) The live C<TemporalCoreConnection*>. An eager client passes it
here; a lazy client leaves it unset and passes C<connect> instead. At
least one of C<ptr> and C<connect> is required.

=item C<connect>

(optional) An async coderef performing the deferred core connect and
resolving to the connection pointer; invoked at most once, from
C<connected_ptr>, on the first RPC of a lazy client (spec R90).

=back

=head1 METHODS

=head2 close

Closes the underlying sdk-core connection and frees its C pointer.
If the owning runtime has already shut down, the FFI free is skipped
(freeing against a torn-down core would be a use-after-free) and only
Perl-side state is released.

=head2 is_closed

Accessor returning the C<is_closed> value.

=head2 connected_ptr

Async. Returns a L<Future> resolving to the raw C<TemporalCoreConnection*>
pointer, performing the deferred core connect first when the client is
lazy and has not connected yet (spec R90). Concurrent callers share the
single in-flight connect through a once-init guard; a failed connect
clears the guard so the next call retries. Every client RPC resolves its
pointer through this method. Internal.

=head2 ptr

Returns the raw C<TemporalCoreConnection*> pointer (for FFI calls),
raising L<Temporalio::Exception::Runtime> when a lazy client has not
connected yet — which is also what prevents building a worker on an
unconnected lazy client. Internal.

=head2 runtime

Accessor returning the C<runtime> value.

=head2 update_api_key

Updates the API key applied to subsequent RPCs on this connection.
Requires an established connection: on an unconnected lazy client it
raises L<Temporalio::Exception::Runtime> (make an RPC first, then rotate).

=cut
