# ABOUTME: Client HTTP CONNECT proxy configuration (spec section 30.2): a
# ABOUTME: required target_host plus an optional basic-auth pair, with a to_ffi
# ABOUTME: building the ClientHttpConnectProxyOptions record for connect.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();

class Temporalio::Client::HttpConnectProxyConfig {
    # target_host is the proxy's "host:port" (required). basic_auth_user /
    # basic_auth_pass map 1:1 to the C struct's username/password (spec section
    # 30.2; the Ruby SDK's two-field auth, the Python class name). The auth
    # fields come as a pair or not at all (xor guard, a minor ergonomic fork —
    # the reference SDKs don't enforce it, but half a pair can only be a bug).
    field $target_host     :param = undef;
    field $basic_auth_user :param = undef;
    field $basic_auth_pass :param = undef;

    ADJUST {
        Temporalio::Exception::Argument->throw(
            message => 'HttpConnectProxyConfig requires a target_host'
                     . ' (the proxy host:port)')
            unless defined $target_host && length $target_host;
        if (defined $basic_auth_user xor defined $basic_auth_pass) {
            Temporalio::Exception::Argument->throw(
                message => 'HttpConnectProxyConfig basic_auth_user and'
                         . ' basic_auth_pass must be provided together or not'
                         . ' at all');
        }
    }

    method target_host     { $target_host }
    method basic_auth_user { $basic_auth_user }
    method basic_auth_pass { $basic_auth_pass }

    # Builds the TemporalCoreClientHttpConnectProxyOptions record; backing
    # buffers are pushed onto @$keep, which the caller must hold for as long as
    # the record may be dereferenced. NULL username/password mean no proxy auth.
    method to_ffi ($keep) {
        my %pair;
        my %value = (
            target_host => $target_host,
            username    => $basic_auth_user,
            password    => $basic_auth_pass,
        );
        for my $field (keys %value) {
            @pair{ "${field}_data", "${field}_size" } =
                Temporalio::Core::FFI::keep_buffer($keep, $value{$field});
        }
        return Temporalio::Core::FFI::ClientHttpConnectProxyOptions->new(%pair);
    }
}

1;

__END__

=head1 NAME

Temporalio::Client::HttpConnectProxyConfig - HTTP CONNECT proxy for client connections

=head1 SYNOPSIS

    use Temporalio::Client;

    my $client = await Temporalio::Client->connect('localhost:7233',
        http_connect_proxy => {
            target_host     => 'proxy:3128',   # required
            basic_auth_user => 'user',         # optional, paired
            basic_auth_pass => 'pass',
        });

=head1 DESCRIPTION

HTTP CONNECT proxy options for L<Temporalio::Client> connections (spec
section 30.2). C<target_host> is the proxy's C<host:port> and is required;
C<basic_auth_user> and C<basic_auth_pass> are optional but must be supplied
together. Passing a bare truthy value or a hashref without C<target_host> to
C<< Temporalio::Client->connect(http_connect_proxy => ...) >> raises
L<Temporalio::Exception::Argument> before any RPC. C<to_ffi(\@keep)> builds
the C<TemporalCoreClientHttpConnectProxyOptions> record (the auth fields land
in the C C<username>/C<password> members), pushing backing buffers onto
C<@keep>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Client::HttpConnectProxyConfig->new(
        target_host     => 'proxy:3128',
        basic_auth_user => 'user',
        basic_auth_pass => 'pass',
    );

Constructs a Temporalio::Client::HttpConnectProxyConfig. Named parameters:

=over 4

=item C<target_host>

(required) The proxy host:port.

=item C<basic_auth_user>

(optional, default C<undef>) Paired with C<basic_auth_pass>.

=item C<basic_auth_pass>

(optional, default C<undef>) Paired with C<basic_auth_user>.

=back

=head1 METHODS

=head2 target_host

Accessor returning the C<target_host> value.

=head2 basic_auth_user

Accessor returning the C<basic_auth_user> value.

=head2 basic_auth_pass

Accessor returning the C<basic_auth_pass> value.

=head2 to_ffi

Returns the C<Temporalio::Core::FFI::ClientHttpConnectProxyOptions> record
built from this config, passed to C<client_connect>.

=cut
