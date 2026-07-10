# ABOUTME: Env-config TLS value class (spec section 31.1): a parsed [profile.tls]
# ABOUTME: block with DataSource cert fields and to_tls_config -> TlsConfig | 0.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Temporalio::Client::TlsConfig ();

# A DataSource is a hashref { path => $p } or { data => $bytes } (spec section
# 31.1 resolved decision: a hashref, not a bare scalar, keeps the path/data
# split unambiguous). The core JSON emits exactly one of the two keys per field;
# a data DataSource arrives as a JSON array of byte ints (Rust Vec<u8>), decoded
# to a scalar by ClientConfigProfile->_from_json before reaching this class.

class Temporalio::EnvConfig::ClientConfigTLS {
    # Tri-state: undef = not configured, 0 = explicitly enabled, 1 = disabled.
    field $disabled                  :param = undef;
    field $server_name               :param = undef;
    field $server_root_ca_cert       :param = undef;    # DataSource | undef
    field $client_cert               :param = undef;    # DataSource | undef
    field $client_private_key        :param = undef;    # DataSource | undef
    # Present in the spec API surface; the core env-config JSON does not carry
    # it, so it stays undef from a parse and is not mapped into connect (matches
    # the reference SDKs, which also do not surface it).
    field $disable_host_verification :param = undef;

    method disabled            { $disabled }
    method server_name         { $server_name }
    method server_root_ca_cert { $server_root_ca_cert }
    method client_cert         { $client_cert }
    method client_private_key  { $client_private_key }
    method disable_host_verification { $disable_host_verification }

    # to_tls_config() — 0 when TLS is explicitly disabled, else a
    # Temporalio::Client::TlsConfig built from the DataSource cert fields. A
    # {path=>} DataSource is passed as a path (TlsConfig slurps it); a {data=>}
    # DataSource is passed as PEM content. undef disabled is NOT disabled
    # (tri-state): it still yields a TlsConfig (spec section 31.2).
    method to_tls_config () {
        return 0 if $disabled;
        return Temporalio::Client::TlsConfig->new(
            server_name => $server_name,
            ca_cert     => _source_scalar($server_root_ca_cert),
            client_cert => _source_scalar($client_cert),
            client_key  => _source_scalar($client_private_key),
        );
    }

    # Reduce a DataSource hashref to the single path-or-content scalar that
    # Temporalio::Client::TlsConfig accepts (it auto-detects PEM-vs-path).
    sub _source_scalar ($source) {
        return undef unless defined $source;
        return $source->{path} if defined $source->{path};
        return $source->{data} if defined $source->{data};
        return undef;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::EnvConfig::ClientConfigTLS - parsed env-config TLS block

=head1 SYNOPSIS

    my $tls = Temporalio::EnvConfig::ClientConfigTLS->new(
        server_name => 'sni.example',
        client_cert => { data => $pem },
        client_private_key => { data => $key },
    );
    my $connect_tls = $tls->to_tls_config;   # 0 | Temporalio::Client::TlsConfig

=head1 DESCRIPTION

A value class for a parsed C<[profile.tls]> block (spec section 31.1). Cert
fields are DataSource hashrefs (C<{ path =E<gt> ... }> or
C<{ data =E<gt> ... }>). C<disabled> is tri-state: C<undef> (not configured),
C<0> (explicitly enabled), C<1> (explicitly disabled).

=head1 METHODS

=head2 disabled / server_name / server_root_ca_cert / client_cert / client_private_key / disable_host_verification

Field accessors.

=head2 to_tls_config

    my $value = $tls->to_tls_config;

Returns C<0> when TLS is explicitly disabled, otherwise a
L<Temporalio::Client::TlsConfig> built from the DataSource cert fields. A
C<{ path =E<gt> ... }> DataSource is read by TlsConfig; a C<{ data =E<gt> ... }>
DataSource is treated as PEM content.

=cut
