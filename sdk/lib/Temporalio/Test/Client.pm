# ABOUTME: Integration-test glue (P10.0.6): a resilient client connect that
# ABOUTME: retries the transient dev-server connect race on a loaded test box.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

package Temporalio::Test::Client;

use Future ();
use Scalar::Util ();
use Temporalio::Test::Worker ();

# connect_with_retry($loop, $connector, %opts) -> the resolved client.
#
# $connector is a coderef returning a FRESH Future per call (so a retry
# re-issues Temporalio::Client->connect). On a loaded 7.8 GiB/no-swap box the
# ephemeral dev server can pass its 60s start_timeout yet bind/accept a moment
# AFTER the bridge's client_connect runs; core's ~5s connect window then expires
# while the socket is not yet listening and the connect fails with a transient
# "Connection failed: ...ConnectionRefused..." / "tcp connect error" /
# "Failed connecting to test server" / UNAVAILABLE. Those are classified by the
# ONE shared Temporalio::Test::Worker::_is_transient_load_error (the same
# classifier used for idempotent reads and teardown), and only those are
# retried: up to %opts{attempts} times (default 10) with a %opts{backoff}
# pause (default 1.5s) between tries — roughly a 15s window for the just-started
# server to come up. A connect is idempotent (it allocates a fresh client and
# leaves no server-side state on failure), so a retry is always safe here.
#
# Any non-transient failure — a TLS-mismatch "Connection failed: ...handshake...",
# a bad-PEM Argument validation error, or any other RpcError — is raised
# immediately and never retried, so this never masks a real misconfiguration. A
# persistent transient failure surfaces after the last attempt.
sub connect_with_retry ($loop, $connector, %opts) {
    my $attempts = $opts{attempts} // 10;
    my $backoff  = $opts{backoff}  // 1.5;
    my $timeout  = $opts{timeout}  // 60;
    for my $attempt (1 .. $attempts) {
        my $future = $connector->();
        # ->without_cancel shields the connect from wait_any's loser-cancel
        # (Future 0.52, pinned by t/unit/future_semantics.t). Without the
        # shield the timeout arm CANCELLED the connect future: a cancelled
        # future is ready-but-not-failed, so the success branch matched it
        # and ->get croaked "was cancelled" (finding T6 / spec R48), and
        # the late connection delivered by core was discarded unreaped
        # (finding L26 / spec R33).
        $loop->await(Future->wait_any(
            $future->without_cancel,
            $loop->timeout_future(after => $timeout)));

        if (!$future->is_ready) {
            # Wedged connect (finding T6 / spec R48): still pending after
            # $timeout. Treat it as a transient stall (same as a connect
            # refused) and retry with a fresh connect; core may still
            # complete THIS one later, so hand it to the reaper first
            # (finding L26 / spec R33).
            _reap_late_connect($future);
            die "connect did not resolve within ${timeout}s\n"
                if $attempt == $attempts;
        }
        elsif (!$future->is_failed) {
            return $future->get;
        }
        else {
            # A resolved failure is classified: only the transient
            # connect-race shapes are retried.
            my $err = ($future->failure)[0];
            die $err
                if $attempt == $attempts
                || !Temporalio::Test::Worker::_is_transient_load_error($err);
        }

        $loop->await($loop->delay_future(after => $backoff)) if $backoff > 0;
    }
    # Unreachable: the loop either returns or dies on the last attempt.
    return;
}

# Finding L26 (spec R33): a connect abandoned by the retry loop is still in
# flight in core, which completes it regardless — the late success is a
# fully-built Temporalio::Client whose core connection would otherwise leak
# (bounded: one connection per wedged attempt). Close it when it lands. A
# late FAILURE has nothing to reap; retrieve it so the abandoned future
# never warns as an unreported failure.
sub _reap_late_connect ($future) {
    $future->on_ready(sub ($f) {
        if ($f->is_failed) {
            my @reported = $f->failure;
            return;
        }
        return if $f->is_cancelled;
        my $client = $f->get;
        warn 'Temporalio::Test::Client: connect completed after its'
           . " timeout; closing the late connection\n";
        $client->connection->close;
        return;
    });
    return;
}

1;

__END__

=encoding utf8

=head1 NAME

Temporalio::Test::Client - resilient dev-server client connect for integration tests

=head1 SYNOPSIS

    use Temporalio::Test::Client ();

    my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
        Temporalio::Client->connect(
            $server->target,
            namespace => 'default',
            runtime   => $runtime,
        );
    });

=head1 DESCRIPTION

Test-only glue (P10.0.6) for DevServer-backed integration tests. On a loaded
host the ephemeral dev server can pass its start timeout yet begin accepting
connections a moment after the bridge attempts C<client_connect>, so core's
short connect-retry window expires against a not-yet-listening socket and the
connect fails transiently (C<ConnectionRefused> / C<tcp connect error> /
C<Failed connecting to test server> / C<UNAVAILABLE>).

C<connect_with_retry> wraps the connect in a bounded retry around exactly those
transient connect-race shapes, classified by the B<one shared>
L<Temporalio::Test::Worker> C<_is_transient_load_error> (the same classifier
that drives idempotent-read and teardown retries — connect, read, and teardown
share one definition of "transient"). A genuine connect failure (TLS mismatch,
bad PEM, or any other error) raises immediately and is never retried.

This lives under C<Temporalio::Test::> alongside
L<Temporalio::Test::DevServer>, L<Temporalio::Test::Worker>, and
L<Temporalio::Test::WorkflowReplay> — author glue, not part of the public SDK
surface.

=head1 FUNCTIONS

=head2 connect_with_retry

    my $client = Temporalio::Test::Client::connect_with_retry(
        $loop, $connector, attempts => 10, backoff => 1.5, timeout => 60);

Awaits C<$connector> (a coderef returning a B<fresh> L<Future> per call) on
C<$loop>, retrying only a transient dev-server connect race up to C<attempts>
times (default 10) with a C<backoff> pause (default 1.5s) between tries.
Returns the resolved client. Non-transient failures surface at once.

A connect still pending after C<timeout> seconds (default 60) is treated as
a wedged transient stall and retried the same way (spec R48); the abandoned
attempt is handed to a reaper so a connection that core establishes late is
closed rather than leaked (spec R33).

=cut
