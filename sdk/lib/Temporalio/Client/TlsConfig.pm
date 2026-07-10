# ABOUTME: Client TLS configuration (spec section 7.2): PEM content-vs-path
# ABOUTME: detection per cert field, plus the ClientTlsOptions record builder.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Core::FFI ();
use Temporalio::Exception::Argument ();

class Temporalio::Client::TlsConfig {
    # Each cert field accepts PEM content (scalar starting with -----BEGIN)
    # or a readable filesystem path, detected automatically; paths are
    # slurped synchronously at construction (spec section 7.3 step 2), so
    # by the time connect goes async only PEM bytes remain. Anything else
    # raises Argument before any RPC (T-cli-connect-3).
    field $ca_cert     :param = undef;
    field $client_cert :param = undef;
    field $client_key  :param = undef;
    field $server_name :param = undef;

    sub _resolve_pem ($field, $value) {
        return undef unless defined $value;
        return $value if $value =~ /^-----BEGIN/;
        if (-f $value && -r _) {
            open my $fh, '<:raw', $value
                or Temporalio::Exception::Argument->throw(
                    message => "TlsConfig $field path '$value' could not be"
                             . " read: $!");
            local $/;
            my $content = <$fh>;
            close $fh;
            return $content;
        }
        Temporalio::Exception::Argument->throw(
            message => "TlsConfig $field is neither PEM content (leading"
                     . " -----BEGIN) nor a readable file: '$value'");
    }

    ADJUST {
        $ca_cert     = _resolve_pem(ca_cert     => $ca_cert);
        $client_cert = _resolve_pem(client_cert => $client_cert);
        $client_key  = _resolve_pem(client_key  => $client_key);
        if (defined $client_cert xor defined $client_key) {
            Temporalio::Exception::Argument->throw(
                message => 'TlsConfig client_cert and client_key must be'
                         . ' provided together (mTLS pair) or not at all');
        }
    }

    method ca_cert     { $ca_cert }
    method client_cert { $client_cert }
    method client_key  { $client_key }
    method server_name { $server_name }

    # Builds the TemporalCoreClientTlsOptions record; backing buffers are
    # pushed onto @$keep, which the caller must hold for as long as the
    # record may be dereferenced. NULL fields mean system CA roots / no SNI
    # override / no mTLS (a bare TlsConfig is exactly `tls => 1`).
    method to_ffi ($keep) {
        my %pair;
        my %value = (
            server_root_ca_cert => $ca_cert,
            domain              => $server_name,
            client_cert         => $client_cert,
            client_private_key  => $client_key,
        );
        for my $field (keys %value) {
            @pair{ "${field}_data", "${field}_size" } =
                Temporalio::Core::FFI::keep_buffer($keep, $value{$field});
        }
        return Temporalio::Core::FFI::ClientTlsOptions->new(%pair);
    }
}

1;

__END__

=head1 NAME

Temporalio::Client::TlsConfig - TLS configuration for client connections

=head1 SYNOPSIS

    use Temporalio::Client::TlsConfig;

    my $tls = Temporalio::Client::TlsConfig->new(
        ca_cert     => $path_or_pem,      # default: system CA roots
        client_cert => $path_or_pem,      # mTLS pair: both or neither
        client_key  => $path_or_pem,
        server_name => 'temporal.cloud',  # SNI / domain override
    );

=head1 DESCRIPTION

TLS options for L<Temporalio::Client> connections (spec section 7.2). Each
cert field accepts literal PEM content (detected by a leading
C<-----BEGIN>) or a readable filesystem path, which is slurped
synchronously at construction; a value that is neither raises
L<Temporalio::Exception::Argument> before any RPC. C<client_cert> and
C<client_key> must be supplied together. C<to_ffi(\@keep)> builds the
C<TemporalCoreClientTlsOptions> record (C<server_name> lands in the
C<domain> member), pushing backing buffers onto C<@keep>.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Client::TlsConfig->new(
        ca_cert => ...,
        client_cert => ...,
        client_key => ...,
        server_name => ...,
    );

Constructs a Temporalio::Client::TlsConfig. Named parameters:

=over 4

=item C<ca_cert>

(optional, default C<undef>)

=item C<client_cert>

(optional, default C<undef>)

=item C<client_key>

(optional, default C<undef>)

=item C<server_name>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 ca_cert

Accessor returning the C<ca_cert> value.

=head2 client_cert

Accessor returning the C<client_cert> value.

=head2 client_key

Accessor returning the C<client_key> value.

=head2 server_name

Accessor returning the C<server_name> value.

=head2 to_ffi

Returns the C<Temporalio::Core::FFI::ClientTlsOptions> record built from this config, passed to C<client_connect>.

=cut
