# ABOUTME: Unit tests for the spec section 30.2 HTTP CONNECT proxy config —
# ABOUTME: HttpConnectProxyConfig->to_ffi record marshalling (T-proxy-1), the
# ABOUTME: xor / bare-truthy Argument guards (T-proxy-2), connect wiring (T-proxy-3).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();
use FFI::Platypus::Buffer ();
use Temporalio::Client ();
use Temporalio::Client::HttpConnectProxyConfig ();
use Temporalio::Core::FFI ();

sub read_buffer ($data, $size) {
    return undef unless defined $data;
    return FFI::Platypus::Buffer::buffer_to_scalar($data, $size);
}

sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub is_argument_exc ($err) {
    return Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument');
}

# ---------------------------------------------------------------------------
# T-proxy-1: to_ffi builds the ClientHttpConnectProxyOptions record non-null
# ---------------------------------------------------------------------------
T2->subtest('HttpConnectProxyConfig->to_ffi marshals all three byte arrays (T-proxy-1)' => sub {
    my @keep;
    my $config = Temporalio::Client::HttpConnectProxyConfig->new(
        target_host     => 'proxy:3128',
        basic_auth_user => 'u',
        basic_auth_pass => 'p',
    );
    T2->is($config->target_host, 'proxy:3128', 'target_host accessor');
    T2->is($config->basic_auth_user, 'u', 'basic_auth_user accessor');
    T2->is($config->basic_auth_pass, 'p', 'basic_auth_pass accessor');

    my $record = $config->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::ClientHttpConnectProxyOptions');
    T2->is(read_buffer($record->target_host_data, $record->target_host_size),
        'proxy:3128', 'target_host lands in target_host byte array');
    T2->is(read_buffer($record->username_data, $record->username_size),
        'u', 'basic_auth_user lands in username (Ruby 1:1 mapping)');
    T2->is(read_buffer($record->password_data, $record->password_size),
        'p', 'basic_auth_pass lands in password');
    T2->ok(scalar @keep, 'backing buffers pushed onto @keep');
});

T2->subtest('no-auth proxy leaves username/password NULL' => sub {
    my @keep;
    my $record = Temporalio::Client::HttpConnectProxyConfig->new(
        target_host => 'proxy:3128',
    )->to_ffi(\@keep);
    T2->is(read_buffer($record->target_host_data, $record->target_host_size),
        'proxy:3128', 'target_host present');
    T2->is(scalar $record->username_data, undef, 'username NULL');
    T2->is(scalar $record->password_data, undef, 'password NULL');
});

# ---------------------------------------------------------------------------
# T-proxy-2: validation — required target_host, xor auth pair
# ---------------------------------------------------------------------------
T2->subtest('missing target_host raises Argument (T-proxy-2)' => sub {
    my $err = exception_from(sub {
        Temporalio::Client::HttpConnectProxyConfig->new(basic_auth_user => 'u',
            basic_auth_pass => 'p');
    });
    T2->ok(is_argument_exc($err), 'no target_host -> Argument')
        or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/target_host/, 'message names target_host');
});

T2->subtest('half an auth pair raises Argument (xor guard, T-proxy-2)' => sub {
    for my $half ([ basic_auth_user => 'u' ], [ basic_auth_pass => 'p' ]) {
        my $err = exception_from(sub {
            Temporalio::Client::HttpConnectProxyConfig->new(
                target_host => 'proxy:3128', @$half);
        });
        T2->ok(is_argument_exc($err),
            "$half->[0] without its pair -> Argument")
            or T2->diag('got: ' . ($err // 'no exception'));
    }
});

# ---------------------------------------------------------------------------
# T-proxy-2: bare-truthy http_connect_proxy => 1 -> Argument (required host)
# ---------------------------------------------------------------------------
T2->subtest('connect with http_connect_proxy => 1 raises Argument (T-proxy-2)' => sub {
    my $err = exception_from(sub {
        Temporalio::Client::connect('Temporalio::Client', 'localhost:7233',
            http_connect_proxy => 1)->get;
    });
    T2->ok(is_argument_exc($err), 'bare-truthy proxy -> Argument')
        or T2->diag('got: ' . ($err // 'no exception'));
    T2->like("$err", qr/target_host/, 'message names required target_host');
});

# ---------------------------------------------------------------------------
# T-proxy-3: _coerce_config accepts hashref or instance for the proxy slot
# ---------------------------------------------------------------------------
T2->subtest('_coerce_config builds HttpConnectProxyConfig from a hashref (T-proxy-3)' => sub {
    my $from_hash = Temporalio::Client::_coerce_config(
        http_connect_proxy => { target_host => 'p:3128' },
        'Temporalio::Client::HttpConnectProxyConfig');
    T2->isa_ok($from_hash, 'Temporalio::Client::HttpConnectProxyConfig');
    T2->is($from_hash->target_host, 'p:3128', 'hashref coerced');

    my $instance = Temporalio::Client::HttpConnectProxyConfig->new(
        target_host => 'p:3128');
    my $passed = Temporalio::Client::_coerce_config(
        http_connect_proxy => $instance,
        'Temporalio::Client::HttpConnectProxyConfig');
    T2->is($passed, $instance, 'instance passes through');

    my $none = Temporalio::Client::_coerce_config(
        http_connect_proxy => undef,
        'Temporalio::Client::HttpConnectProxyConfig');
    T2->is($none, undef, 'undef stays undef (no proxy)');
});

T2->done_testing;
