# ABOUTME: Owns a live TemporalCoreConnection pointer (spec section 7.3):
# ABOUTME: api-key rotation via the bridge, explicit close, free-on-reclaim,
# ABOUTME: the deferred (lazy) connect shared by concurrent first RPCs, and
# ABOUTME: the rpc_call funnel behind the raw service handles (spec R91).
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;
use Scalar::Util ();
use Temporalio::Client::OperatorService ();
use Temporalio::Client::WorkflowService ();
use Temporalio::Common::Options ();
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::Runtime ();

class Temporalio::Client::Connection {
    # TemporalCoreRpcService discriminator values (header lines 8-14:
    # Workflow=1, Operator, Cloud, Test, Health).
    my %RPC_SERVICE = (
        workflow => 1,
        operator => 2,
        cloud    => 3,
        test     => 4,
        health   => 5,
    );

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

    # rpc_call($rpc_name, $request_msg, %opts), async. The single funnel
    # every RPC goes through (spec section 7.5), both the high-level client
    # methods (via Client::_rpc_call) and the raw service handles (spec R91):
    # encodes the request proto, calls temporal_core_client_rpc_call over the
    # callback bridge, decodes the typed response, and maps failures onto the
    # exception hierarchy via Temporalio::Core::Callback::rpc_error_for.
    # Lives here rather than on the Client because it needs only the
    # connection pointer and the runtime, matching Python where the rpc
    # funnel is the service client's, not the Client's (service.py
    # _BridgeServiceClient._rpc_call; parity audit client finding 1).
    #
    # %opts:
    #   service        => workflow|operator|cloud|test|health (default workflow)
    #   retry          => boolean (default 0, a raw single-shot call, the
    #                     Python raw-service default; every high-level client
    #                     method passes retry => 1 and core applies the client
    #                     RetryConfig)
    #   timeout        => seconds (default 0 = no timeout)
    #   response_class => proto class (default: request class s/Request$/Response/)
    #   error_context  => hashref merged into the rpc_error_for arguments
    #                     (e.g. workflow_id/workflow_type for ALREADY_EXISTS)
    async method rpc_call ($rpc, $request, %opts) {
        Temporalio::Common::Options::assert_known_keys(
            'rpc_call', \%opts,
            { service => 1, retry => 1, timeout => 1, response_class => 1,
              error_context => 1 });
        my $service        = delete $opts{service} // 'workflow';
        my $retry          = exists $opts{retry} ? !!delete $opts{retry} : 0;
        my $timeout        = delete $opts{timeout} // 0;
        my $response_class = delete $opts{response_class};
        my $error_context  = delete $opts{error_context} // {};
        my $service_code = $RPC_SERVICE{$service}
            // Temporalio::Exception::Argument->throw(
                message => "unknown RPC service '$service' (expected one of "
                         . join(', ', sort keys %RPC_SERVICE) . ')');
        Temporalio::Exception::Argument->throw(
            message => 'rpc_call requires a proto request message object')
            unless Scalar::Util::blessed($request) && $request->can('encode');
        $response_class //= ref($request) =~ s/Request\z/Response/r;
        Temporalio::Exception::Argument->throw(
            message => "cannot derive a response class for '" . ref($request)
                     . "'; pass response_class")
            unless $response_class ne ref($request)
                && $response_class->can('decode');

        # Resolve the live connection pointer first: a lazy client performs
        # its deferred core connect here, on the first RPC, and concurrent
        # first RPCs share the single in-flight connect through the
        # once-init guard (spec R90; parity audit client finding 3).
        my $connection_ptr = await $self->connected_ptr;

        # Build the TemporalCoreRpcCallOptions record. @keep and the record
        # itself are lexicals held across the await; per the header, the
        # options must live through the callback.
        my @keep;
        my ($rpc_data, $rpc_size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $rpc);
        my ($req_data, $req_size) =
            Temporalio::Core::FFI::keep_buffer(\@keep, $request->encode);
        my $options = Temporalio::Core::FFI::RpcCallOptions->new(
            service              => $service_code,
            rpc_data             => $rpc_data,
            rpc_size             => $rpc_size,
            req_data             => $req_data,
            req_size             => $req_size,
            retry                => $retry ? 1 : 0,
            metadata_data        => undef,
            metadata_size        => 0,
            binary_metadata_data => undef,
            binary_metadata_size => 0,
            timeout_millis       => int($timeout * 1000),
            cancellation_token   => undef,
        );

        # The rpc completion always resolves done (Callback.pm kind 4) with
        # the raw fields; "either success or failure_message are always
        # present" (header), so a defined failure_message IS the error case.
        my $completion = await Temporalio::Core::Callback->issue_async(
            $runtime, rpc => sub ($user_data, $trampoline) {
                Temporalio::Core::FFI::client_rpc_call(
                    $connection_ptr, $options, $user_data, $trampoline);
            });

        if (defined $completion->{failure_message}) {
            die Temporalio::Core::Callback::rpc_error_for(
                status_code => $completion->{status_code},
                message     => $completion->{failure_message},
                details     => $completion->{failure_details},
                rpc         => $rpc,
                %$error_context,
            );
        }
        return $response_class->decode($completion->{success} // '');
    }

    # The raw service handles (spec R91; Python _client.py:307-322 via
    # service.py, where the per-service passthrough objects hang off the
    # service client). A fresh handle per call: the generated methods live
    # at package level, the handle itself is a thin connection wrapper, and
    # not caching it avoids a Connection <-> handle reference cycle that
    # would defeat the DESTROY free-with-warning path.
    method workflow_service () {
        $self->_assert_open;
        return Temporalio::Client::WorkflowService->new(connection => $self);
    }

    method operator_service () {
        $self->_assert_open;
        return Temporalio::Client::OperatorService->new(connection => $self);
    }

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

    # Raw service handles + the rpc funnel behind them (spec R91).
    my $op       = $connection->operator_service;
    my $response = await $connection->rpc_call('GetSystemInfo', $request);

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

The connection also owns the rpc funnel (spec R91; Python parity
C<service.py>, where the rpc call is the service client's): C<rpc_call>
encodes a request proto, issues C<temporal_core_client_rpc_call> over the
callback bridge, decodes the typed response, and maps failures onto the
exception hierarchy. The high-level client's C<_rpc_call> delegates here
with C<< retry => 1 >>; the raw service handles returned by
C<workflow_service> and C<operator_service> call it single-shot.

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

=head2 rpc_call($rpc, $request, %opts)

Async. The rpc funnel (spec section 7.5 / R91): encodes the proto request
message, issues C<$rpc> (the CamelCase name the c-bridge dispatches on) via
C<temporal_core_client_rpc_call>, and resolves to the decoded typed
response; a failure completion dies with the mapped exception from the
L<Temporalio::Core::Callback> MUST-match table. Options: C<service>
(C<workflow>|C<operator>|C<cloud>|C<test>|C<health>, default C<workflow>),
C<retry> (default 0, a raw single-shot call; the high-level client passes 1
so core applies its retry config), C<timeout> (seconds, default none),
C<response_class> (default: the request class with C<Request> replaced by
C<Response>), and C<error_context> (extra arguments merged into the
exception mapping). On a lazy client the first call performs the deferred
core connect (spec R90).

=head2 runtime

Accessor returning the C<runtime> value.

=head2 workflow_service

Returns a fresh L<Temporalio::Client::WorkflowService> raw handle over this
connection (spec R91).

=head2 operator_service

Returns a fresh L<Temporalio::Client::OperatorService> raw handle over this
connection (spec R91).

=head2 update_api_key

Updates the API key applied to subsequent RPCs on this connection.
Requires an established connection: on an unconnected lazy client it
raises L<Temporalio::Exception::Runtime> (make an RPC first, then rotate).

=cut
