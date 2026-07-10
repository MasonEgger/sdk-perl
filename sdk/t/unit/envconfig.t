# ABOUTME: Unit tests for spec section 31 client environment configuration —
# ABOUTME: the env-config FFI option-struct build, JSON-into-value-class parse,
# ABOUTME: fail-string -> Argument, and to_connect_config mapping (T-envcfg-1..9).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();
use JSON::PP ();
use File::Temp ();
use Temporalio::EnvConfig ();
use Temporalio::EnvConfig::ClientConfigTLS ();
use Temporalio::EnvConfig::ClientConfigProfile ();
use Temporalio::EnvConfig::ClientConfig ();
use Temporalio::Client::TlsConfig ();
use Temporalio::Core::FFI ();

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub is_argument_exc ($err) {
    return Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument');
}

# A minimal valid TOML config exercising two profiles, a TLS block, grpc_meta.
my $TOML = <<'EOT';
[profile.default]
address = "default.example:7233"
namespace = "default-ns"
grpc_meta = { my-key = "my-value" }

[profile.prod]
address = "prod.example:7233"
namespace = "prod-ns"
api_key = "sekret"

[profile.prod.tls]
server_name = "prod.example"
EOT

# ---------------------------------------------------------------------------
# T-envcfg-1: options-struct built correctly from each kwarg combination.
# We assert the record marshals the byte arrays from path/data/env_vars and
# the bool flags, by reading the populated record fields back.
# ---------------------------------------------------------------------------
T2->subtest('profile-load options struct marshals kwargs (T-envcfg-1)' => sub {
    my @keep;
    my $rec = Temporalio::EnvConfig::_build_profile_options(
        \@keep,
        profile            => 'prod',
        path               => '/tmp/temporal.toml',
        config_file_strict => 1,
        disable_file       => 0,
        disable_env        => 1,
        env_vars           => { TEMPORAL_ADDRESS => 'x:1' },
    );
    T2->ok(defined $rec->profile_data, 'profile byte-array populated');
    T2->ok(defined $rec->path_data,    'path byte-array populated');
    T2->is($rec->config_file_strict, 1, 'config_file_strict flag set');
    T2->is($rec->disable_env, 1, 'disable_env flag set');
    T2->is($rec->disable_file, 0, 'disable_file flag clear');
    T2->ok(defined $rec->env_vars_data, 'env_vars JSON byte-array populated');

    # data variant: passing data leaves path NULL.
    my @keep2;
    my $rec2 = Temporalio::EnvConfig::_build_profile_options(
        \@keep2, data => "[profile.default]\n");
    T2->ok(!defined $rec2->path_data, 'path NULL when data given');
    T2->ok(defined $rec2->data_data,  'data byte-array populated');
});

# ---------------------------------------------------------------------------
# T-envcfg-2: load (all-profiles) parses multi-profile JSON into value classes.
# Hermetic: pass the TOML via config_source, env disabled by load() semantics.
# ---------------------------------------------------------------------------
T2->subtest('load parses multi-profile config (T-envcfg-2)' => sub {
    my $config = Temporalio::EnvConfig::ClientConfig->load(
        config_source     => $TOML,
        override_env_vars => {},
    );
    T2->isa_ok($config, ['Temporalio::EnvConfig::ClientConfig'], 'ClientConfig');
    my $profiles = $config->profiles;
    T2->is(ref $profiles, 'HASH', 'profiles is a hashref');
    T2->ok(exists $profiles->{default}, 'default profile present');
    T2->ok(exists $profiles->{prod},    'prod profile present');
    T2->isa_ok($profiles->{default},
        ['Temporalio::EnvConfig::ClientConfigProfile'], 'profile value class');
    T2->is($profiles->{default}->address, 'default.example:7233',
        'default address parsed');
    T2->is($profiles->{default}->namespace, 'default-ns',
        'default namespace parsed');
});

# ---------------------------------------------------------------------------
# T-envcfg-3: a full TLS block + grpc_meta parse into the value classes.
# ---------------------------------------------------------------------------
T2->subtest('TLS block and grpc_meta parse (T-envcfg-3)' => sub {
    my $profile = Temporalio::EnvConfig::ClientConfigProfile->load(
        profile           => 'default',
        config_source     => $TOML,
        override_env_vars => {},
    );
    T2->is($profile->grpc_meta, { 'my-key' => 'my-value' },
        'grpc_meta parsed into a hashref');

    my $prod = Temporalio::EnvConfig::ClientConfigProfile->load(
        profile           => 'prod',
        config_source     => $TOML,
        override_env_vars => {},
    );
    T2->is($prod->api_key, 'sekret', 'api_key parsed');
    T2->isa_ok($prod->tls, ['Temporalio::EnvConfig::ClientConfigTLS'],
        'tls is a ClientConfigTLS value class');
    T2->is($prod->tls->server_name, 'prod.example', 'tls server_name parsed');
});

# ---------------------------------------------------------------------------
# T-envcfg-4: parse a representative FFI JSON directly (codec present but not
# surfaced; DataSource path + data byte-array forms) into value classes.
# ---------------------------------------------------------------------------
T2->subtest('parse representative FFI JSON, incl DataSource forms (T-envcfg-4)' => sub {
    my $json = JSON::PP->new->encode({
        address   => 'j.example:7233',
        namespace => 'jns',
        api_key   => 'k',
        codec     => { endpoint => 'http://codec' },    # parsed, not surfaced
        grpc_meta => { a => 'b' },
        tls       => {
            disabled    => JSON::PP::false,
            server_name => 'sni.example',
            # path DataSource and data (Vec<u8> -> array of byte ints) DataSource
            server_ca_cert => { path => '/etc/ca.pem' },
            client_cert    => { data => [ unpack 'C*', 'CERTBYTES' ] },
            client_key     => { data => [ unpack 'C*', 'KEYBYTES' ] },
        },
    });
    my $profile = Temporalio::EnvConfig::ClientConfigProfile->_from_json($json);
    T2->is($profile->address,   'j.example:7233', 'address');
    T2->is($profile->namespace, 'jns',            'namespace');
    T2->is($profile->grpc_meta, { a => 'b' },     'grpc_meta');
    my $tls = $profile->tls;
    T2->is($tls->disabled, 0, 'disabled parsed as 0 (JSON false)');
    T2->is($tls->server_root_ca_cert, { path => '/etc/ca.pem' },
        'server CA DataSource is a path hashref');
    T2->is($tls->client_cert, { data => 'CERTBYTES' },
        'client cert DataSource data decoded from byte array');
    T2->is($tls->client_private_key, { data => 'KEYBYTES' },
        'client key DataSource data decoded from byte array');
});

# ---------------------------------------------------------------------------
# T-envcfg-5: a fail-string return maps to Argument — profile not found.
# ---------------------------------------------------------------------------
T2->subtest('missing profile -> Argument (T-envcfg-5)' => sub {
    my $err = exception_from sub {
        Temporalio::EnvConfig::ClientConfigProfile->load(
            profile           => 'does-not-exist',
            config_source     => $TOML,
            override_env_vars => {},
        );
    };
    T2->ok(is_argument_exc($err),
        'missing profile raises Temporalio::Exception::Argument')
        or T2->diag("got: $err");
});

# ---------------------------------------------------------------------------
# T-envcfg-6: strict-mode unknown key -> Argument; malformed TOML -> Argument.
# ---------------------------------------------------------------------------
T2->subtest('strict unknown key and bad TOML -> Argument (T-envcfg-6)' => sub {
    my $strict_bad = <<'EOT';
[profile.default]
address = "x:1"
bogus_unknown_key = "boom"
EOT
    my $err = exception_from sub {
        Temporalio::EnvConfig::ClientConfigProfile->load(
            profile            => 'default',
            config_source      => $strict_bad,
            config_file_strict => 1,
            override_env_vars  => {},
        );
    };
    T2->ok(is_argument_exc($err), 'strict unknown key -> Argument')
        or T2->diag("got: " . ($err // 'no error'));

    my $err2 = exception_from sub {
        Temporalio::EnvConfig::ClientConfigProfile->load(
            profile           => 'default',
            config_source     => "this is = = not valid toml [[[",
            override_env_vars => {},
        );
    };
    T2->ok(is_argument_exc($err2), 'malformed TOML -> Argument')
        or T2->diag("got: " . ($err2 // 'no error'));
});

# ---------------------------------------------------------------------------
# T-envcfg-7: to_connect_config mapping — address->target, grpc_meta->rpc_metadata.
# ---------------------------------------------------------------------------
T2->subtest('to_connect_config base mapping (T-envcfg-7)' => sub {
    my $profile = Temporalio::EnvConfig::ClientConfigProfile->new(
        address   => 'h:7233',
        namespace => 'ns',
        grpc_meta => { k => 'v' },
    );
    my $cfg = $profile->to_connect_config;
    T2->is($cfg->{target}, 'h:7233', 'address -> target');
    T2->is($cfg->{namespace}, 'ns', 'namespace passes through');
    T2->is($cfg->{rpc_metadata}, { k => 'v' }, 'grpc_meta -> rpc_metadata');
    T2->ok(!exists $cfg->{tls}, 'no tls key without api_key or tls block');
});

# ---------------------------------------------------------------------------
# T-envcfg-8: api_key implies tls=>1; an explicit tls block overrides it.
# ---------------------------------------------------------------------------
T2->subtest('api_key implies tls; explicit tls overrides (T-envcfg-8)' => sub {
    my $p1 = Temporalio::EnvConfig::ClientConfigProfile->new(
        address => 'h:7233', api_key => 'k');
    my $c1 = $p1->to_connect_config;
    T2->is($c1->{api_key}, 'k', 'api_key passes through');
    T2->is($c1->{tls}, 1, 'api_key implies tls => 1');

    # explicit disabled tls overrides the api_key implication
    my $p2 = Temporalio::EnvConfig::ClientConfigProfile->new(
        address => 'h:7233',
        api_key => 'k',
        tls     => Temporalio::EnvConfig::ClientConfigTLS->new(disabled => 1),
    );
    my $c2 = $p2->to_connect_config;
    T2->is($c2->{tls}, 0, 'explicit disabled tls overrides api_key => tls 0');

    # explicit enabled tls block -> a TlsConfig instance
    my $p3 = Temporalio::EnvConfig::ClientConfigProfile->new(
        address => 'h:7233',
        tls     => Temporalio::EnvConfig::ClientConfigTLS->new(
            server_name => 'sni.example'),
    );
    my $c3 = $p3->to_connect_config;
    T2->isa_ok($c3->{tls}, ['Temporalio::Client::TlsConfig'],
        'enabled tls block -> Temporalio::Client::TlsConfig');
    T2->is($c3->{tls}->server_name, 'sni.example', 'TlsConfig SNI carried over');
});

# ---------------------------------------------------------------------------
# T-envcfg-9: DataSource path-vs-data -> TlsConfig; disabled tri-state.
# ---------------------------------------------------------------------------
T2->subtest('to_tls_config DataSource resolution + disabled tri-state (T-envcfg-9)' => sub {
    # disabled => 1 short-circuits to 0
    my $disabled = Temporalio::EnvConfig::ClientConfigTLS->new(disabled => 1);
    T2->is($disabled->to_tls_config, 0, 'disabled tls -> 0');

    # undef disabled => still build a TlsConfig (tri-state: undef != disabled)
    my $bare = Temporalio::EnvConfig::ClientConfigTLS->new;
    T2->isa_ok($bare->to_tls_config, ['Temporalio::Client::TlsConfig'],
        'undef-disabled -> TlsConfig (not disabled)');

    # data DataSource: PEM content passed straight through to TlsConfig.
    my $pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n";
    my $key = "-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n";
    my $data_tls = Temporalio::EnvConfig::ClientConfigTLS->new(
        server_name        => 's',
        client_cert        => { data => $pem },
        client_private_key => { data => $key },
    );
    my $tc = $data_tls->to_tls_config;
    T2->isa_ok($tc, ['Temporalio::Client::TlsConfig'], 'data -> TlsConfig');
    T2->is($tc->client_cert, $pem, 'client_cert data passed through');
    T2->is($tc->client_key,  $key, 'client_key data passed through');

    # path DataSource: TlsConfig slurps the file at the given path.
    my $ca_fh = File::Temp->new(SUFFIX => '.pem');
    print {$ca_fh} "-----BEGIN CERTIFICATE-----\nCAFILE\n-----END CERTIFICATE-----\n";
    $ca_fh->flush;
    my $path_tls = Temporalio::EnvConfig::ClientConfigTLS->new(
        server_root_ca_cert => { path => "$ca_fh" },
    );
    my $tc2 = $path_tls->to_tls_config;
    T2->like($tc2->ca_cert, qr/CAFILE/, 'path DataSource slurped into ca_cert');
});

T2->done_testing;
