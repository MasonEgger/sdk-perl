# ABOUTME: Asserts Connection close and DESTROY skip client_free once the
# ABOUTME: owning runtime has shut down (spec R2; finding L2).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use IO::Async::Loop ();
use Temporalio::Client::Connection ();
use Temporalio::Core::FFI ();
use Temporalio::Runtime ();

# Global Requirement 5 guard-assertion tests (the use-after-free window is
# not deterministically executable from a test). Code trace:
#
# - Finding L2 (R2): Client/Connection.pm:50-66 — both close and DESTROY —
#   called client_free (Core/FFI.pm:606-608, temporal_core_client_free) with
#   no runtime-liveness check. client_free drops the core connection on the
#   runtime's Tokio threads; after Runtime->shutdown those threads and the
#   core runtime are torn down, so the free runs against freed core state
#   (use-after-free). Destruction order was left to Perl reclamation.
#
# The fix guards the free with a runtime-liveness check factored into one
# private method both close and DESTROY reach, skipping the FFI free and
# releasing only Perl-side state when the runtime is gone.
#
# Every subtest spies on client_free WITHOUT forwarding to the real FFI
# function: a recorded call after shutdown IS the defect being asserted
# against, and the spy keeps the synthetic pointer from ever reaching C.

my $FAKE_PTR = 0xdead_beef;

T2->subtest('R2: explicit close after runtime shutdown skips client_free' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $conn    = Temporalio::Client::Connection->new(
        runtime => $runtime,
        ptr     => $FAKE_PTR,
    );

    $runtime->shutdown;

    my @calls;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::client_free = sub ($ptr) { push @calls, $ptr };
    use warnings 'redefine';

    my $lived = eval { $conn->close; 1 };
    T2->ok($lived, 'close after runtime shutdown does not die')
        or T2->diag($@);
    T2->is(scalar @calls, 0,
        'client_free is NOT called once the runtime is shut down');
    T2->ok($conn->is_closed, 'Perl-side state is still released (closed)');
});

T2->subtest('R2: DESTROY after runtime shutdown skips client_free' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my @calls;
    my @warnings;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::client_free = sub ($ptr) { push @calls, $ptr };
    use warnings 'redefine';
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    my $lived = eval {
        my $conn = Temporalio::Client::Connection->new(
            runtime => $runtime,
            ptr     => $FAKE_PTR,
        );
        $runtime->shutdown;
        # $conn is reclaimed here: DESTROY runs with the runtime dead.
        1;
    };
    T2->ok($lived, 'DESTROY after runtime shutdown does not die')
        or T2->diag($@);
    T2->is(scalar @calls, 0,
        'client_free is NOT called from DESTROY once the runtime is shut down');
    T2->like(
        join('', @warnings),
        qr/reclaimed without.*close/s,
        'the reclaim-without-close warning still fires',
    );
});

T2->subtest('R2 control: close with a live runtime still frees exactly once' => sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);
    my $conn    = Temporalio::Client::Connection->new(
        runtime => $runtime,
        ptr     => $FAKE_PTR,
    );

    my @calls;
    no warnings 'redefine';
    local *Temporalio::Core::FFI::client_free = sub ($ptr) { push @calls, $ptr };
    use warnings 'redefine';

    $conn->close;
    T2->is(\@calls, [$FAKE_PTR],
        'live-runtime close calls client_free exactly once with the pointer');

    $conn->close;
    T2->is(scalar @calls, 1, 'close stays idempotent (no second free)');

    $runtime->shutdown;
});

T2->done_testing;
