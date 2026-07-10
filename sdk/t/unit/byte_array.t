# ABOUTME: Tests Temporalio::Core::ByteArray: wrap/bytes round-trip (T-ba-1),
# ABOUTME: bytes-after-free raises (T-ba-2), DESTROY frees once (T-ba-3),
# ABOUTME: idempotent free (T-ba-4), dead-runtime warn-and-skip failure mode.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();
use FFI::Platypus::Buffer qw(scalar_to_buffer);
use Temporalio::Core::FFI ();

# Spec section 4.3: ByteArray wraps a *const TemporalCoreByteArray returned
# from the bridge, owns the free path (via a weak runtime reference), and
# exposes the contents as a Perl scalar.

# Minimal stand-in for Temporalio::Runtime (P0.9): ByteArray only needs the
# ->core_ptr accessor returning the TemporalCoreRuntime pointer.
package Local::MockRuntime {
    sub new ($class, $core_ptr) { bless { core_ptr => $core_ptr }, $class }
    sub core_ptr ($self) { $self->{core_ptr} }
}

# A real runtime for the real free path (plan P0.7 NOTE). NULL telemetry and
# 0 heartbeat millis are the bridge defaults (verified in P0.6).
my $options = Temporalio::Core::FFI::RuntimeOptions->new(
    telemetry                        => undef,
    worker_heartbeat_interval_millis => 0,
);
my $result           = Temporalio::Core::FFI::runtime_new($options);
my $runtime_fail     = $result->fail;
my $core_runtime_ptr = $result->runtime;
defined $core_runtime_ptr && !defined $runtime_fail
    or T2->bail_out('could not create a real core runtime for the free path');

# Craft a TemporalCoreByteArray over a Perl-owned buffer with disable_free=1
# (the bridge's byte_array_free early-returns on disable_free, so passing it
# to the real free is safe — verified in sdk-core-c-bridge runtime.rs).
# Returns an opaque pointer; keeps the payload SV and record alive for the
# duration of the test file.
my @keep_alive;
sub craft_byte_array ($payload) {
    my ($data, $size) = scalar_to_buffer($payload);
    my $record = Temporalio::Core::FFI::ByteArray->new(
        data         => $data,
        size         => $size,
        cap          => $size,
        disable_free => 1,
    );
    push @keep_alive, \$payload, $record;
    return Temporalio::Core::FFI::ffi()->cast(
        'record(Temporalio::Core::FFI::ByteArray)*' => 'opaque', $record);
}

T2->subtest('module loads' => sub {
    my $loaded = eval { require Temporalio::Core::ByteArray; 1 };
    T2->ok($loaded, 'require Temporalio::Core::ByteArray succeeds')
        or T2->diag($@);
});

T2->subtest('wrap + bytes round-trip (T-ba-1)' => sub {
    my $payload = "known contents \x01\x02\x00 with embedded NUL";
    my $ptr     = craft_byte_array($payload);
    my $runtime = Local::MockRuntime->new($core_runtime_ptr);

    my $ba = Temporalio::Core::ByteArray->wrap($ptr, $runtime);
    T2->isa_ok($ba, 'Temporalio::Core::ByteArray');
    T2->is($ba->bytes,     $payload, 'bytes returns the crafted contents');
    T2->is($ba->to_string, $payload, 'to_string is an alias for bytes');
    T2->is($ba->bytes,     $payload, 'second call returns the cached scalar');

    # Real free through the real runtime ptr; disable_free=1 makes the
    # bridge a no-op, so this exercises the FFI call without a double free.
    $ba->free;
    T2->pass('real byte_array_free returned without crashing');
});

T2->subtest('bytes after free raises Runtime (T-ba-2)' => sub {
    my $runtime = Local::MockRuntime->new($core_runtime_ptr);
    my $ba = Temporalio::Core::ByteArray->wrap(craft_byte_array('gone'), $runtime);
    $ba->free;

    my $err = do { local $@; eval { $ba->bytes }; $@ };
    my $is_runtime_exc = Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Runtime');
    T2->ok($is_runtime_exc, 'bytes after free raises Temporalio::Exception::Runtime')
        or T2->diag("got: $err");
    T2->like("$err", qr/^ByteArray freed/, 'message is "ByteArray freed"');
});

T2->subtest('DESTROY invokes free exactly once (T-ba-3)' => sub {
    my $free_calls = 0;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::byte_array_free = sub { $free_calls++ };

    my $runtime = Local::MockRuntime->new($core_runtime_ptr);
    {
        my $ba = Temporalio::Core::ByteArray->wrap(craft_byte_array('scoped'), $runtime);
        T2->is($ba->bytes, 'scoped', 'bytes works before scope exit');
    }
    T2->is($free_calls, 1, 'DESTROY called the FFI free exactly once');

    # Explicit free first, then DESTROY at scope exit: still exactly once.
    $free_calls = 0;
    {
        my $ba = Temporalio::Core::ByteArray->wrap(craft_byte_array('early'), $runtime);
        $ba->free;
    }
    T2->is($free_calls, 1, 'explicit free + DESTROY frees exactly once');
});

T2->subtest('repeated free is idempotent (T-ba-4)' => sub {
    my $free_calls = 0;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::byte_array_free = sub { $free_calls++ };

    my $runtime = Local::MockRuntime->new($core_runtime_ptr);
    my $ba = Temporalio::Core::ByteArray->wrap(craft_byte_array('again'), $runtime);
    $ba->free for 1 .. 3;
    T2->is($free_calls, 1, 'three free calls invoke the FFI free once');
});

T2->subtest('dead runtime weakref: warn and skip free (spec 4.3 failure mode)' => sub {
    my $free_calls = 0;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::byte_array_free = sub { $free_calls++ };

    my $runtime = Local::MockRuntime->new($core_runtime_ptr);
    my $ba = Temporalio::Core::ByteArray->wrap(craft_byte_array('leaked'), $runtime);
    undef $runtime;    # only strong reference dies; ByteArray's is weak

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $ba->free;
    }
    T2->is($free_calls, 0, 'FFI free was skipped');
    T2->is(scalar @warnings, 1, 'exactly one warning was emitted');
    T2->like($warnings[0], qr/runtime already gone/,
        'warning names the dead-runtime cause');

    my $err = do { local $@; eval { $ba->bytes }; $@ };
    my $is_runtime_exc = Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Runtime');
    T2->ok($is_runtime_exc, 'byte array is marked freed afterward');

    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $ba->free;
    }
    T2->is(scalar @warnings, 1, 'repeated free after skip stays silent');
    T2->is($free_calls, 0, 'repeated free after skip still skips the FFI free');
});

Temporalio::Core::FFI::runtime_free($core_runtime_ptr);

T2->done_testing;
