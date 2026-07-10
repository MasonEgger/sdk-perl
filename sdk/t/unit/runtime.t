# ABOUTME: Tests Temporalio::Runtime lifecycle: construction (T-rt-1), lazy
# ABOUTME: default (T-rt-2), set_default semantics (T-rt-3), use-after-shutdown
# ABOUTME: raises (T-rt-5), idempotent shutdown, and the DESTROY warning.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();

# Spec section 4.2: Temporalio::Runtime wraps TemporalCoreRuntime, owns the
# shim callback queue and the wakeup fd, and tears all three down in a fixed
# shutdown sequence. Tests shut runtimes down explicitly (relying on DESTROY
# is fragile and warns).

T2->subtest('module loads' => sub {
    my $loaded = eval { require Temporalio::Runtime; 1 };
    T2->ok($loaded, 'require Temporalio::Runtime succeeds')
        or T2->diag($@);
});

T2->subtest('T-rt-1: new with defaults' => sub {
    my $rt = Temporalio::Runtime->new;
    T2->ok(defined $rt, 'constructed a runtime with default options');

    my $core_ptr = $rt->core_ptr;
    T2->ok(defined $core_ptr, 'core runtime pointer is set');

    my $queue_ptr = $rt->queue_ptr;
    T2->ok(defined $queue_ptr, 'shim callback queue is allocated');

    my $read_handle = $rt->read_handle;
    my $fileno      = defined $read_handle ? fileno($read_handle) : undef;
    T2->ok(defined $fileno, 'wakeup fd read end is an open filehandle');

    $rt->shutdown;
    T2->pass('explicit shutdown succeeds');
});

T2->subtest('T-rt-2: default is lazy and idempotent' => sub {
    my $first  = Temporalio::Runtime->default;
    my $second = Temporalio::Runtime->default;
    T2->ok(defined $first, 'default lazily constructs a runtime');
    T2->is(
        Scalar::Util::refaddr($second), Scalar::Util::refaddr($first),
        'repeated default calls return the same instance',
    );
    $first->shutdown;
});

T2->subtest('T-rt-3: set_default semantics' => sub {
    my $rt1 = Temporalio::Runtime->new;
    my $rt2 = Temporalio::Runtime->new;

    Temporalio::Runtime->set_default($rt1);
    T2->is(
        Scalar::Util::refaddr(Temporalio::Runtime->default),
        Scalar::Util::refaddr($rt1),
        'set_default installs the runtime as the default',
    );

    my $error = do {
        local $@;
        eval { Temporalio::Runtime->set_default($rt2) };
        $@;
    };
    T2->ok(
        Scalar::Util::blessed($error)
            && $error->isa('Temporalio::Exception::Runtime'),
        'second set_default raises Temporalio::Exception::Runtime by default',
    ) or T2->diag($error);
    T2->like(
        Scalar::Util::blessed($error) ? $error->message : "$error",
        qr/\ADefault runtime already set\b/,
        'error message matches the spec wording',
    );
    T2->is(
        Scalar::Util::refaddr(Temporalio::Runtime->default),
        Scalar::Util::refaddr($rt1),
        'failed set_default leaves the previous default in place',
    );

    Temporalio::Runtime->set_default($rt2, error_if_already_set => 0);
    T2->is(
        Scalar::Util::refaddr(Temporalio::Runtime->default),
        Scalar::Util::refaddr($rt2),
        'error_if_already_set => 0 replaces the default',
    );
    my $old_error = do {
        local $@;
        eval { $rt1->core_ptr };
        $@;
    };
    T2->ok(
        Scalar::Util::blessed($old_error)
            && $old_error->isa('Temporalio::Exception::Runtime')
            && $old_error->message =~ /\ARuntime is shut down\b/,
        'replaced default was shut down',
    ) or T2->diag($old_error);

    $rt2->shutdown;
});

T2->subtest('T-rt-5: operations after shutdown raise' => sub {
    my $rt = Temporalio::Runtime->new;
    $rt->shutdown;

    for my $op (qw(core_ptr queue_ptr read_handle)) {
        my $error = do {
            local $@;
            eval { $rt->$op };
            $@;
        };
        T2->ok(
            Scalar::Util::blessed($error)
                && $error->isa('Temporalio::Exception::Runtime')
                && $error->message =~ /\ARuntime is shut down\b/,
            "$op after shutdown raises 'Runtime is shut down'",
        ) or T2->diag($error);
    }
});

T2->subtest('shutdown is idempotent (frees exactly once)' => sub {
    my $runtime_frees = 0;
    my $queue_frees   = 0;
    my $orig_runtime_free = \&Temporalio::Core::FFI::runtime_free;
    my $orig_queue_free   = \&Temporalio::Core::FFI::queue_free;
    local *Temporalio::Core::FFI::runtime_free =
        sub { $runtime_frees++; $orig_runtime_free->(@_) };
    local *Temporalio::Core::FFI::queue_free =
        sub { $queue_frees++; $orig_queue_free->(@_) };

    my $rt = Temporalio::Runtime->new;
    $rt->shutdown;
    my $lived = eval { $rt->shutdown; 1 };
    T2->ok($lived, 'second shutdown is a no-op (does not die)')
        or T2->diag($@);
    T2->is($runtime_frees, 1, 'runtime_free called exactly once');
    T2->is($queue_frees,   1, 'queue_free called exactly once');
});

T2->subtest('DESTROY shuts down but warns' => sub {
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        my $rt = Temporalio::Runtime->new;
        undef $rt;
    }
    T2->is(scalar @warnings, 1, 'reclaiming a live runtime warns once')
        or T2->diag(@warnings);
    T2->like(
        $warnings[0] // '',
        qr/call ->shutdown explicitly/,
        'warning tells the caller to shut down explicitly',
    );
});

T2->done_testing;
