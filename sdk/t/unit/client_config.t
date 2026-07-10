# ABOUTME: Tests the client config classes (spec section 7.2): TlsConfig PEM
# ABOUTME: content-vs-path detection (T-cli-connect-3 precondition), RetryConfig
# ABOUTME: and KeepAliveConfig MUST-match defaults, and the identity default.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Temp ();
use Scalar::Util ();

my @classes = qw(
    Temporalio::Client::TlsConfig
    Temporalio::Client::RetryConfig
    Temporalio::Client::KeepAliveConfig
);

T2->subtest('modules load' => sub {
    for my $class (@classes) {
        my $loaded = eval "require $class; 1";
        T2->ok($loaded, "require $class succeeds") or T2->diag($@);
    }
});

# Captures the exception a code block dies with; returns it (or undef).
sub exception_from ($code) {
    my $err = do { local $@; eval { $code->(); 1 } ? undef : $@ };
    return $err;
}

sub is_argument_exc ($err) {
    return Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Argument');
}

my $PEM = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n";

T2->subtest('TlsConfig detects PEM content vs path vs garbage (spec 7.2)' => sub {
    # Literal PEM content (leading -----BEGIN) passes through unchanged.
    my $content = Temporalio::Client::TlsConfig->new(ca_cert => $PEM);
    T2->is($content->ca_cert, $PEM, 'PEM content kept verbatim');

    # A readable path is slurped synchronously (spec 7.3 step 2).
    my $tmp = File::Temp->new(SUFFIX => '.pem');
    print {$tmp} $PEM;
    close $tmp;
    my $path = Temporalio::Client::TlsConfig->new(ca_cert => "$tmp");
    T2->is($path->ca_cert, $PEM, 'path is slurped to the PEM content');

    # Garbage (neither PEM nor readable file) raises Argument before any RPC
    # (T-cli-connect-3 precondition).
    for my $field (qw(ca_cert client_cert client_key)) {
        my $err = exception_from(sub {
            Temporalio::Client::TlsConfig->new(
                # client_cert/client_key must come in pairs; satisfy the
                # other half with valid PEM so only $field is at fault.
                ($field eq 'ca_cert' ? () : map { $_ => $PEM }
                    grep { $_ ne $field } qw(client_cert client_key)),
                $field => 'definitely/not-a-pem-or-a-readable-file',
            );
        });
        T2->ok(is_argument_exc($err), "garbage $field raises Argument")
            or T2->diag('got: ' . ($err // 'no exception'));
        T2->like("$err", qr/\Q$field\E/, "message names $field");
    }

    # mTLS material comes in pairs (the bridge rejects half a pair; fail
    # Perl-side before any RPC instead).
    for my $half ([ client_cert => $PEM ], [ client_key => $PEM ]) {
        my $err = exception_from(sub {
            Temporalio::Client::TlsConfig->new(@$half);
        });
        T2->ok(is_argument_exc($err),
            "$half->[0] without its pair raises Argument")
            or T2->diag('got: ' . ($err // 'no exception'));
    }

    my $named = Temporalio::Client::TlsConfig->new(server_name => 'temporal.cloud');
    T2->is($named->server_name, 'temporal.cloud', 'server_name accessor');
});

# --- to_ffi builders --------------------------------------------------------
# Field-value assertions against temporal-sdk-core-c-bridge.h at the pinned
# tag (struct ClientTlsOptions / ClientRetryOptions / ClientKeepAliveOptions).

use FFI::Platypus::Buffer ();

sub read_buffer ($data, $size) {
    return undef unless defined $data;
    return FFI::Platypus::Buffer::buffer_to_scalar($data, $size);
}

T2->subtest('TlsConfig->to_ffi builds ClientTlsOptions' => sub {
    require Temporalio::Core::FFI;
    my @keep;
    my $record = Temporalio::Client::TlsConfig->new(
        ca_cert     => $PEM,
        client_cert => $PEM,
        client_key  => $PEM,
        server_name => 'temporal.cloud',
    )->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::ClientTlsOptions');
    T2->is(read_buffer($record->server_root_ca_cert_data,
                       $record->server_root_ca_cert_size),
        $PEM, 'ca_cert lands in server_root_ca_cert');
    T2->is(read_buffer($record->domain_data, $record->domain_size),
        'temporal.cloud', 'server_name lands in domain');
    T2->is(read_buffer($record->client_cert_data, $record->client_cert_size),
        $PEM, 'client_cert byte array ref');
    T2->is(read_buffer($record->client_private_key_data,
                       $record->client_private_key_size),
        $PEM, 'client_key lands in client_private_key');
    T2->ok(scalar @keep, 'backing buffers were pushed onto @keep');

    # tls => 1 semantics: a bare TlsConfig has every field NULL (system roots).
    my $bare = Temporalio::Client::TlsConfig->new->to_ffi(\@keep);
    T2->is(scalar $bare->server_root_ca_cert_data, undef, 'bare ca_cert NULL');
    T2->is(scalar $bare->domain_data,              undef, 'bare domain NULL');
    T2->is(scalar $bare->client_cert_data,         undef, 'bare client_cert NULL');
    T2->is(scalar $bare->client_private_key_data,  undef, 'bare client_key NULL');
});

T2->subtest('RetryConfig defaults match sdk-core / spec 7.2 exactly' => sub {
    # MUST-match table (spec 7.2), verified against sdk-python service.py
    # RetryConfig and sdk-ruby client/connection.rb RPCRetryOptions.
    my $retry = Temporalio::Client::RetryConfig->new;
    T2->is($retry->initial_interval,     0.1, 'initial_interval 0.1s');
    T2->is($retry->randomization_factor, 0.2, 'randomization_factor 0.2');
    T2->is($retry->multiplier,           1.5, 'multiplier 1.5');
    T2->is($retry->max_interval,         5.0, 'max_interval 5.0s');
    T2->is($retry->max_elapsed_time,     10.0, 'max_elapsed_time 10.0s');
    T2->is($retry->max_retries,          10,  'max_retries 10');

    my @keep;
    my $record = $retry->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::ClientRetryOptions');
    T2->is($record->initial_interval_millis, 100,    'initial 100ms');
    T2->is($record->randomization_factor,    0.2,    'jitter 0.2');
    T2->is($record->multiplier,              1.5,    'multiplier 1.5');
    T2->is($record->max_interval_millis,     5_000,  'max interval 5000ms');
    T2->is($record->max_elapsed_time_millis, 10_000, 'max elapsed 10000ms');
    T2->is($record->max_retries,             10,     'max retries 10');

    # 0 = unlimited (the bridge maps 0 millis to None).
    my $unlimited = Temporalio::Client::RetryConfig->new(max_elapsed_time => 0)
        ->to_ffi(\@keep);
    T2->is($unlimited->max_elapsed_time_millis, 0, '0 stays 0 (unlimited)');
});

T2->subtest('KeepAliveConfig defaults interval=30/timeout=15 (spec 7.2)' => sub {
    my $keep_alive = Temporalio::Client::KeepAliveConfig->new;
    T2->is($keep_alive->interval, 30, 'interval 30s');
    T2->is($keep_alive->timeout,  15, 'timeout 15s');

    my @keep;
    my $record = $keep_alive->to_ffi(\@keep);
    T2->isa_ok($record, 'Temporalio::Core::FFI::ClientKeepAliveOptions');
    T2->is($record->interval_millis, 30_000, 'interval 30000ms');
    T2->is($record->timeout_millis,  15_000, 'timeout 15000ms');
});

T2->subtest('identity defaults to "<pid>@<hostname>" (spec 7.1)' => sub {
    # Convention verified against sdk-python service.py
    # (f"{os.getpid()}@{socket.gethostname()}") and sdk-ruby connection.rb.
    require Sys::Hostname;
    my $loaded = eval { require Temporalio::Client; 1 };
    T2->ok($loaded, 'require Temporalio::Client succeeds') or T2->diag($@);
    T2->is(
        Temporalio::Client->default_identity,
        $$ . '@' . Sys::Hostname::hostname(),
        'default identity is pid@hostname',
    );
    T2->like(Temporalio::Client->default_identity, qr/^\d+@\S+$/,
        'identity shape is <pid>@<hostname>');
});

T2->done_testing;
