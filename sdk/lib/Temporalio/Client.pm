# ABOUTME: Temporal client (spec section 7): async connect over the callback
# ABOUTME: bridge, holding the connection, namespace, identity, and converter.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';
use feature 'try';
no warnings 'experimental::try';

use Future::AsyncAwait;
use Scalar::Util ();
use Sys::Hostname ();
use Temporalio::Converter::Data;
use Temporalio::Core::Callback ();
use Temporalio::Core::FFI ();
use Temporalio::Client::Connection ();
use Temporalio::Client::KeepAliveConfig ();
use Temporalio::Client::RetryConfig ();
use Temporalio::Client::TlsConfig ();
use Temporalio::Exception::Argument ();
use Temporalio::Exception::RpcError ();
use Temporalio::Runtime ();
use Temporalio::SDK ();

class Temporalio::Client {
    # TemporalCoreRpcService discriminator values (header lines 8-14:
    # Workflow=1, Operator, Cloud, Test, Health).
    my %RPC_SERVICE = (
        workflow => 1,
        operator => 2,
        cloud    => 3,
        test     => 4,
        health   => 5,
    );

    field $connection     :param;    # Temporalio::Client::Connection
    field $namespace      :param;
    field $identity       :param;
    field $data_converter :param;
    field $runtime        :param;

    method connection     { $connection }
    method namespace      { $namespace }
    method identity       { $identity }
    method data_converter { $data_converter }
    method runtime        { $runtime }

    # Rotation is manual and explicit (spec section 7.3): no refresh timer,
    # no refresh-on-UNAUTHENTICATED. Synchronous, no RPC.
    method update_api_key ($api_key) {
        $connection->update_api_key($api_key);
        return;
    }

    # _rpc_call($rpc_name, $request_msg, %opts) — async. The single funnel
    # every client method's RPC goes through (spec section 7.5): encodes the
    # request proto, calls temporal_core_client_rpc_call over the callback
    # bridge, decodes the typed response, and maps failures onto the
    # exception hierarchy via Temporalio::Core::Callback::rpc_error_for.
    #
    # %opts:
    #   service        => workflow|operator|cloud|test|health (default workflow)
    #   retry          => boolean (default 1 — every high-level client method
    #                     sets retry, and core applies the client RetryConfig;
    #                     pass 0 for a raw single-shot call)
    #   timeout        => seconds (default 0 = no timeout)
    #   response_class => proto class (default: request class s/Request$/Response/)
    #   error_context  => hashref merged into the rpc_error_for arguments
    #                     (e.g. workflow_id/workflow_type for ALREADY_EXISTS)
    async method _rpc_call ($rpc, $request, %opts) {
        my $service        = delete $opts{service} // 'workflow';
        my $retry          = exists $opts{retry} ? !!delete $opts{retry} : 1;
        my $timeout        = delete $opts{timeout} // 0;
        my $response_class = delete $opts{response_class};
        my $error_context  = delete $opts{error_context} // {};

        if (my @unknown = sort keys %opts) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown _rpc_call option(s): '
                         . join(', ', @unknown));
        }
        my $service_code = $RPC_SERVICE{$service}
            // Temporalio::Exception::Argument->throw(
                message => "unknown RPC service '$service' (expected one of "
                         . join(', ', sort keys %RPC_SERVICE) . ')');
        Temporalio::Exception::Argument->throw(
            message => '_rpc_call requires a proto request message object')
            unless Scalar::Util::blessed($request) && $request->can('encode');
        $response_class //= ref($request) =~ s/Request\z/Response/r;
        Temporalio::Exception::Argument->throw(
            message => "cannot derive a response class for '" . ref($request)
                     . "'; pass response_class")
            unless $response_class ne ref($request)
                && $response_class->can('decode');

        # Build the TemporalCoreRpcCallOptions record. @keep and the record
        # itself are lexicals held across the await — per the header, the
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
                    $connection->ptr, $options, $user_data, $trampoline);
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

    # Default client identity, "<pid>@<hostname>" (spec section 7.1;
    # convention verified against sdk-python service.py and sdk-ruby
    # client/connection.rb).
    sub default_identity ($class) {
        return $$ . '@' . Sys::Hostname::hostname();
    }

    # Coerce a config kwarg: undef/0 stays undef, a hashref becomes
    # $config_class->new(%$hashref), an instance passes through, anything
    # else raises Argument.
    sub _coerce_config ($name, $value, $config_class) {
        return undef unless $value;
        return $config_class->new if !ref $value;    # e.g. tls => 1
        return $config_class->new(%$value) if ref $value eq 'HASH';
        return $value
            if Scalar::Util::blessed($value) && $value->isa($config_class);
        Temporalio::Exception::Argument->throw(
            message => "$name must be a boolean, a hashref, or a"
                     . " $config_class instance");
    }

    # connect($target, %options) — async (spec section 7.1/7.3): validates
    # and builds everything synchronously (bad PEM and friends fail before
    # any RPC), then awaits temporal_core_client_connect via the callback
    # bridge and returns a connected client.
    async sub connect ($class, $target, %options) {
        my $runtime        = delete $options{runtime};
        my $namespace      = delete $options{namespace} // 'default';
        my $api_key        = delete $options{api_key};
        my $tls            = delete $options{tls};
        my $identity       = delete $options{identity}
                          // $class->default_identity;
        my $rpc_metadata   = delete $options{rpc_metadata};
        my $retry          = delete $options{retry};
        # Keep-alive defaults ON with the spec 7.2 defaults (matching the
        # reference SDKs); pass keep_alive => 0 to disable.
        my $keep_alive     = exists $options{keep_alive}
            ? delete $options{keep_alive}
            : {};
        my $data_converter = delete $options{data_converter}
                          // Temporalio::Converter::Data->new;
        my $lazy           = delete $options{lazy} // 0;

        if (my @unknown = sort keys %options) {
            Temporalio::Exception::Argument->throw(
                message => 'unknown Temporalio::Client->connect option(s): '
                         . join(', ', @unknown));
        }
        Temporalio::Exception::Argument->throw(
            message => 'Temporalio::Client->connect requires a target'
                     . ' host:port')
            unless defined $target && length $target;
        Temporalio::Exception::Argument->throw(
            message => 'lazy client connections are not supported in v0.1')
            if $lazy;

        $runtime //= Temporalio::Runtime->default;
        my $tls_config =
            _coerce_config(tls => $tls, 'Temporalio::Client::TlsConfig');
        my $retry_config =
            _coerce_config(retry => $retry, 'Temporalio::Client::RetryConfig')
            // Temporalio::Client::RetryConfig->new;
        my $keep_alive_config = _coerce_config(
            keep_alive => $keep_alive, 'Temporalio::Client::KeepAliveConfig');

        # The bridge parses target_url as a URL; the scheme encodes the TLS
        # choice exactly as the reference SDKs do (sdk-python service.py).
        my $target_url = ($tls_config ? 'https' : 'http') . "://$target";

        # rpc_metadata entries are MetadataRef items, each "key\nvalue";
        # keys cannot contain newlines (per the header).
        my @metadata_entries;
        for my $key (sort keys %{ $rpc_metadata // {} }) {
            my $value = $rpc_metadata->{$key} // '';
            if ("$key$value" =~ /\n/) {
                Temporalio::Exception::Argument->throw(
                    message => 'rpc_metadata keys and values must not contain'
                             . " newlines (key '$key')");
            }
            push @metadata_entries, "$key\n$value";
        }

        # Build the TemporalCoreConnectionOptions record tree. @keep (and
        # the record itself, as a lexical across the await) must live until
        # the connect callback fires — client.rs: options must live through
        # the callback.
        my @keep;
        my sub ref_pair ($name, $value) {
            my ($data, $size) =
                Temporalio::Core::FFI::keep_buffer(\@keep, $value);
            return ("${name}_data" => $data, "${name}_size" => $size);
        }
        my ($metadata_data, $metadata_count) =
            Temporalio::Core::FFI::keep_byte_array_ref_array(
                \@keep, \@metadata_entries);

        my $options_record = Temporalio::Core::FFI::ConnectionOptions->new(
            ref_pair(target_url     => $target_url),
            ref_pair(client_name    => 'temporal-perl'),
            ref_pair(client_version => $Temporalio::SDK::VERSION),
            metadata_data        => $metadata_data,
            metadata_size        => $metadata_count,
            binary_metadata_data => undef,
            binary_metadata_size => 0,
            ref_pair(api_key  => $api_key),
            ref_pair(identity => $identity),
            tls_options        => $tls_config
                ? Temporalio::Core::FFI::keep_record(
                      \@keep, $tls_config->to_ffi(\@keep))
                : undef,
            retry_options      => Temporalio::Core::FFI::keep_record(
                \@keep, $retry_config->to_ffi(\@keep)),
            keep_alive_options => $keep_alive_config
                ? Temporalio::Core::FFI::keep_record(
                      \@keep, $keep_alive_config->to_ffi(\@keep))
                : undef,
            http_connect_proxy_options       => undef,
            grpc_override_callback           => undef,
            grpc_override_callback_user_data => undef,
            dns_load_balancing_options       => undef,
        );

        # Spec section 7.3 step 5: a non-null fail byte array (surfaced by
        # the callback layer as Exception::Bridge) becomes RpcError with
        # the decoded message.
        my $connection_ptr;
        try {
            $connection_ptr = await Temporalio::Core::Callback->issue_async(
                $runtime, connect => sub ($user_data, $trampoline) {
                    Temporalio::Core::FFI::client_connect(
                        $runtime->core_ptr, $options_record,
                        $user_data, $trampoline);
                });
        }
        catch ($error) {
            if (Scalar::Util::blessed($error)
                && $error->isa('Temporalio::Exception::Bridge'))
            {
                Temporalio::Exception::RpcError->throw(
                    message => $error->message);
            }
            die $error;
        }

        return $class->new(
            connection => Temporalio::Client::Connection->new(
                runtime => $runtime,
                ptr     => $connection_ptr,
            ),
            namespace      => $namespace,
            identity       => $identity,
            data_converter => $data_converter,
            runtime        => $runtime,
        );
    }
}

1;

__END__

=head1 NAME

Temporalio::Client - client for a Temporal server

=head1 SYNOPSIS

    use Temporalio::Client;

    my $client = await Temporalio::Client->connect(
        'localhost:7233',                  # positional, required
        namespace    => 'default',
        api_key      => $token,            # rotate via update_api_key
        tls          => 1 | { ... } | Temporalio::Client::TlsConfig->new(...),
        identity     => "$$\@$hostname",   # default: "<pid>@<hostname>"
        rpc_metadata => { 'x-extra' => 'foo' },
        retry        => { ... } | Temporalio::Client::RetryConfig->new(...),
        keep_alive   => { interval => 30, timeout => 15 },
        data_converter => $converter,      # default Temporalio::Converter::Data->new
        runtime      => $rt,               # default Temporalio::Runtime->default
    );

    $client->update_api_key($new_token);

=head1 DESCRIPTION

The Temporal client (spec section 7). C<connect> is async: it resolves the
runtime, validates and builds the C<TemporalCoreConnectionOptions> tree
synchronously — TLS PEM material is detected (content vs path) and slurped
before the async call, so a bad PEM raises
L<Temporalio::Exception::Argument> before any RPC — then awaits
C<temporal_core_client_connect> through the callback bridge. On failure it
raises L<Temporalio::Exception::RpcError> with the decoded bridge message.
On success it returns a client holding the
L<Temporalio::Client::Connection>, namespace, identity, data converter,
and runtime.

C<tls>, C<retry>, and C<keep_alive> each accept a boolean, a hashref of
constructor arguments, or a config instance (L<Temporalio::Client::TlsConfig>,
L<Temporalio::Client::RetryConfig>, L<Temporalio::Client::KeepAliveConfig>).
Retry defaults match sdk-core exactly and retries run inside sdk-core, not
the Perl layer. Keep-alive defaults on (30s/15s); disable with
C<< keep_alive => 0 >>. C<update_api_key> rotates the bearer token on the
live connection synchronously; rotation is always manual (spec section
7.3). Lazy connections are deferred past v0.1.

Every client RPC funnels through the private C<_rpc_call> helper: it
encodes the request proto, calls C<temporal_core_client_rpc_call> over the
callback bridge with C<retry> set by default (retries run inside sdk-core
against the client retry config), decodes the typed response, and maps
failures onto the exception hierarchy via the spec section 7.5 MUST-match
table in L<Temporalio::Core::Callback>.

Workflow operations (C<start_workflow> and friends, spec section 7.4)
arrive in later plan steps.

=cut
