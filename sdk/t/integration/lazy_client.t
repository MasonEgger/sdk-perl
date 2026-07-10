# ABOUTME: R90 (parity audit client finding 3) acceptance: connect(lazy => 1)
# ABOUTME: returns a client without connecting; the core gRPC connect is
# ABOUTME: deferred to the first RPC (where a failure then surfaces), and the
# ABOUTME: eager path still connects (and fails) at construct. Python parity
# ABOUTME: _client.py:151,205-207 / service.py _BridgeServiceClient.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";
use SubprocessGuard qw(run_guarded);

# Code trace (spec R90 / parity audit client finding 3): the pre-fix
# Client.pm accepted `lazy` in assert_known_keys and R66 documented it, but
# any true value raised Argument "not supported in v0.1". Python's
# _BridgeServiceClient.connect (service.py) builds the client and skips the
# bridge connect when config.lazy; every RPC then funnels through
# _connected_client(), which connects once under a lock. The scenarios here
# pin the observable halves of that contract:
#   * eager (lazy absent) to an unreachable target fails AT CONSTRUCT;
#   * lazy => 1 to the SAME unreachable target constructs fine (proof no
#     connect was attempted) and the failure surfaces on the FIRST RPC;
#   * against a live dev server, a lazy client's first RPCs (two, fired
#     concurrently, sharing the once-init deferred connect) both succeed.
# The once-init guard itself is pinned deterministically in
# t/unit/lazy_connection.t; the dev-server scenario here is the live
# positive path.
#
# Process shape: nothing Temporal-flavored loads in THIS process (the
# SubprocessGuard contract); each guarded child requires the SDK stack after
# its own fork.

# A target nothing listens on. Port 1 (tcpmux) is privileged and unbound on
# any sane dev host; connection-refused is immediate, so no timeout tuning.
my $UNREACHABLE = '127.0.0.1:1';

# --- scenario 1: unreachable target, eager vs lazy --------------------------

sub lazy_vs_eager_unreachable () {
    require Future;
    require IO::Async::Loop;
    require Scalar::Util;
    require Temporalio::Runtime;
    require Temporalio::Client;

    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my sub settle ($future, $what) {
        $loop->await(Future->wait_any(
            $future->without_cancel, $loop->timeout_future(after => 20)));
        die "$what did not resolve within 20s\n" unless $future->is_ready;
        return;
    }

    # Eager (lazy absent): the connect attempt happens inside connect()
    # itself, so the unreachable target fails the construct.
    my $eager = Temporalio::Client->connect($UNREACHABLE, runtime => $runtime);
    settle($eager, 'eager connect');
    die "eager connect to an unreachable target unexpectedly succeeded\n"
        unless $eager->failure;
    my ($eager_error) = $eager->failure;
    die "eager connect failed with the wrong class: $eager_error\n"
        unless Scalar::Util::blessed($eager_error)
        && $eager_error->isa('Temporalio::Exception::RpcError');

    # Lazy: the SAME unreachable target must construct without error,
    # because no connect is attempted until the first RPC.
    my $lazy_f = Temporalio::Client->connect(
        $UNREACHABLE, lazy => 1, runtime => $runtime);
    settle($lazy_f, 'lazy connect');
    my $client = $lazy_f->get;    # dies if the construct attempted a connect
    die "lazy connect returned a non-client\n"
        unless Scalar::Util::blessed($client)
        && $client->isa('Temporalio::Client');

    # First RPC: the deferred connect runs here and its failure surfaces
    # from the call, not the construct.
    my $rpc = $client->start_workflow(
        'LazyProbe', [],
        id         => "lazy-probe-$$",
        task_queue => "lazy-probe-$$",
    );
    settle($rpc, 'first RPC on the lazy client');
    die "first RPC on a lazy client to an unreachable target succeeded\n"
        unless $rpc->failure;
    my ($rpc_error) = $rpc->failure;
    die "first RPC failed with the wrong class: $rpc_error\n"
        unless Scalar::Util::blessed($rpc_error)
        && $rpc_error->isa('Temporalio::Exception::RpcError');

    $client->connection->close;
    $runtime->shutdown;
    return 1;
}

my %unreachable = run_guarded(\&lazy_vs_eager_unreachable, timeout => 90);
T2->ok($unreachable{ok},
    'unreachable target: eager connect fails at construct, lazy connect '
  . 'succeeds and the failure surfaces on the first RPC')
    or T2->diag($unreachable{reason});

# --- scenario 2: live dev server, deferred connect works --------------------

# Gate (CLAUDE.md): skip when the temporal CLI is unavailable; offline CI
# stays green on scenario 1 alone.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}

T2->subtest('live dev server: the deferred connect happens on first RPC' => sub {
    T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
        unless defined $cli && -x $cli;

    my %live = run_guarded(sub {
        require Future;
        require IO::Async::Loop;
        require Scalar::Util;
        require Temporalio::Runtime;
        require Temporalio::Test::DevServer;
        require Temporalio::Client;

        my $loop    = IO::Async::Loop->new;
        my $runtime = Temporalio::Runtime->new(loop => $loop);
        my $server  = Temporalio::Test::DevServer->start(
            runtime       => $runtime,
            existing_path => $cli,
            log_level     => 'warn',
        );

        # Everything after the server start runs under an eval so a failing
        # scenario still shuts the server down: a child that dies with the
        # dev server up ORPHANS it, and the orphan CLI inherits this child's
        # stdout (prove's TAP pipe), wedging prove until the server is
        # killed by hand (observed on this file's own RED run).
        my $ok = eval {
            my $lazy_f = Temporalio::Client->connect(
                $server->target, lazy => 1, runtime => $runtime);
            $loop->await(Future->wait_any(
                $lazy_f->without_cancel, $loop->timeout_future(after => 20)));
            die "lazy connect did not resolve within 20s\n"
                unless $lazy_f->is_ready;
            my $client = $lazy_f->get;

            # Two first RPCs in flight at once: both must succeed while
            # sharing the single deferred connect (the R90.3 once-init
            # guard; the deterministic single-invocation proof is
            # t/unit/lazy_connection.t).
            my @starts = map {
                $client->start_workflow(
                    'LazyProbe', [],
                    id         => "lazy-live-$_-$$",
                    task_queue => "lazy-live-$$",
                )
            } 1, 2;
            my $both = Future->needs_all(@starts);
            $loop->await(Future->wait_any(
                $both->without_cancel, $loop->timeout_future(after => 30)));
            die "concurrent first RPCs did not resolve within 30s\n"
                unless $both->is_ready;
            die 'concurrent first RPCs on a lazy client failed: '
                . scalar($both->failure) . "\n"
                if $both->failure;

            $client->connection->close;
            1;
        };
        my $error = $@;
        $server->shutdown;
        $runtime->shutdown;
        die $error if !$ok;
        return 1;
    }, timeout => 120);

    T2->ok($live{ok},
        'lazy client against a live dev server: construct makes no RPC, '
      . 'two concurrent first RPCs share the deferred connect and succeed')
        or T2->diag($live{reason});
});

T2->done_testing;
