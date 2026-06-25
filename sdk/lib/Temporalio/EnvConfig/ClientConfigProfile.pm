# ABOUTME: Env-config profile value class (spec section 31.1): a parsed profile
# ABOUTME: with load (single-profile FFI) and to_connect_config -> connect kwargs.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use JSON::PP ();
use Temporalio::EnvConfig ();
use Temporalio::EnvConfig::ClientConfigTLS ();

class Temporalio::EnvConfig::ClientConfigProfile {
    field $address   :param = undef;
    field $namespace :param = undef;
    field $api_key   :param = undef;
    field $tls       :param = undef;    # ClientConfigTLS | undef
    field $grpc_meta :param = undef;    # hashref | undef
    # codec is parsed by core but deliberately not surfaced (spec section 31.1
    # resolved decision, matching the reference SDKs).

    ADJUST { $grpc_meta //= {}; }

    method address   { $address }
    method namespace { $namespace }
    method api_key   { $api_key }
    method tls       { $tls }
    method grpc_meta { $grpc_meta }

    # load(%kwargs) — single-profile loader with env overrides (spec section
    # 31.1). config_source (path-or-content) splits into the path/data option
    # fields: a value that names a readable file is a path, otherwise it is
    # treated as inline TOML content (mirrors the reference _source_to_path_and_data,
    # which uses Path vs str; here a scalar is content unless it is an existing
    # file path). disable_env / disable_file / config_file_strict and
    # override_env_vars pass straight through to the FFI.
    sub load ($class, %kw) {
        my %opts = _source_to_options(delete $kw{config_source});
        my $json = Temporalio::EnvConfig::load_client_config_profile(
            profile            => $kw{profile},
            %opts,
            disable_file       => $kw{disable_file},
            disable_env        => $kw{disable_env},
            config_file_strict => $kw{config_file_strict},
            env_vars           => $kw{override_env_vars},
        );
        return $class->_from_hash($json);
    }

    # _from_json($json_scalar) — parse a profile JSON string into the class.
    sub _from_json ($class, $json) {
        my $hash = JSON::PP->new->utf8->decode($json);
        return $class->_from_hash($hash);
    }

    # _from_hash($hashref) — build the class from a decoded profile hashref
    # (the core JSON profile shape: address/namespace/api_key/tls/codec/grpc_meta).
    sub _from_hash ($class, $h) {
        return $class->new(
            address   => $h->{address},
            namespace => $h->{namespace},
            api_key   => $h->{api_key},
            tls       => _tls_from_hash($h->{tls}),
            grpc_meta => $h->{grpc_meta},
        );
    }

    # Build a ClientConfigTLS from the decoded tls hashref, decoding each
    # DataSource's data byte-array (Rust Vec<u8> -> JSON array of ints) back to
    # a scalar so the cert content survives the JSON round-trip.
    sub _tls_from_hash ($t) {
        return undef unless defined $t;
        return Temporalio::EnvConfig::ClientConfigTLS->new(
            disabled            => _json_bool($t->{disabled}),
            server_name         => $t->{server_name},
            server_root_ca_cert => _data_source($t->{server_ca_cert}),
            client_cert         => _data_source($t->{client_cert}),
            client_private_key  => _data_source($t->{client_key}),
        );
    }

    # Normalize a DataSource hashref from the JSON: pass a path through, and
    # decode a data byte-array into a scalar. Returns the hashref form the
    # value class stores ({ path => } or { data => }), or undef.
    sub _data_source ($d) {
        return undef unless defined $d;
        return { path => $d->{path} } if defined $d->{path};
        if (defined $d->{data}) {
            my $bytes = ref $d->{data} eq 'ARRAY'
                ? pack('C*', @{ $d->{data} })
                : $d->{data};
            return { data => $bytes };
        }
        return undef;
    }

    # JSON::PP booleans stringify oddly; normalize to a 0/1/undef tri-state.
    sub _json_bool ($v) {
        return undef unless defined $v;
        return $v ? 1 : 0;
    }

    # _source_to_options($config_source) — map a path-or-content scalar to the
    # path/data option kwargs. undef -> neither (core uses default file
    # locations). An existing readable file -> path; anything else -> data
    # (inline TOML content).
    sub _source_to_options ($source) {
        return () unless defined $source;
        # Inline TOML content contains newlines; only a single-line scalar can be
        # a real path, so guard the filesystem probe to avoid a bogus stat (and
        # its "filename containing newline" warning) on config bodies.
        return (path => $source)
            if $source !~ /\n/ && -f $source && -r _;
        return (data => $source);
    }

    # to_connect_config() — map the parsed profile into a hashref of
    # Temporalio::Client->connect kwargs (spec section 31.2). The caller deletes
    # 'target' for the positional slot. Mirrors envconfig.py:222-241 /
    # env_config.rb:206-222: address->target, namespace, api_key (implies
    # tls=>1 unless an explicit tls block overrides it), grpc_meta->rpc_metadata.
    method to_connect_config () {
        my %config;
        $config{target}    = $address   if defined $address && length $address;
        $config{namespace} = $namespace if defined $namespace;
        if (defined $api_key) {
            $config{api_key} = $api_key;
            $config{tls}     = 1;    # api_key implies TLS; an explicit block overrides below
        }
        if (defined $tls) {
            $config{tls} = $tls->to_tls_config;    # 0 | Temporalio::Client::TlsConfig
        }
        $config{rpc_metadata} = $grpc_meta if $grpc_meta && %$grpc_meta;
        return \%config;
    }
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::EnvConfig::ClientConfigProfile - parsed env-config profile

=head1 SYNOPSIS

    my $profile = Temporalio::EnvConfig::ClientConfigProfile->load(
        profile => 'prod');
    my %connect = %{ $profile->to_connect_config };
    my $target  = delete $connect{target};

=head1 DESCRIPTION

A value class for a single parsed client configuration profile (spec section
31.1): C<address>, C<namespace>, C<api_key>, C<tls>
(a L<Temporalio::EnvConfig::ClientConfigTLS> or undef), and C<grpc_meta>. The
codec block is parsed by core but not surfaced.

=head1 METHODS

=head2 load

    my $profile = Temporalio::EnvConfig::ClientConfigProfile->load(
        profile => $name,
        config_source => $path_or_content,
        disable_file => $bool,
        disable_env => $bool,
        config_file_strict => $bool,
        override_env_vars => \%env,
    );

Loads a single profile via the env-config FFI, applying env overrides. A load
failure raises L<Temporalio::Exception::Argument>.

=head2 address / namespace / api_key / tls / grpc_meta

Field accessors. C<grpc_meta> is always a hashref (possibly empty).

=head2 to_connect_config

    my $hashref = $profile->to_connect_config;

Maps the profile into L<Temporalio::Client/connect> kwargs: C<address> to
C<target>, C<api_key> (implying C<tls =E<gt> 1> unless an explicit TLS block
overrides), C<grpc_meta> to C<rpc_metadata>. The caller deletes C<target> for
the positional argument.

=cut
