# ABOUTME: Unit tests for worker shutdown-time transport-error tolerance
# ABOUTME: (P10.0): a connection reset during worker_finalize_shutdown must be
# ABOUTME: swallowed so it never rejects the run future / dirties process exit.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Worker ();
use Temporalio::Exception::Bridge ();
use Temporalio::Exception::Runtime ();

# The classifier decides whether a failure raised while finalizing worker
# shutdown is an EXPECTED shutdown-time transport teardown (server connection
# reset / closed while the shutdown_worker RPC was in flight) — which the SDK
# must tolerate rather than propagate to a non-zero process exit — versus a real
# error that must still surface.
my $classify = Temporalio::Worker->can('_shutdown_error_is_tolerable');
T2->ok($classify, '_shutdown_error_is_tolerable is defined');

# A bridge failure carrying the core's shutdown_worker transport-reset message
# is tolerable. This is the exact text core emits when the dev server drops the
# connection during teardown (hyper ConnectionReset behind a tonic transport
# error), reproduced verbatim from signals_queries.t stderr.
my $reset = Temporalio::Exception::Bridge->new(
    message =>
        q{Status { code: Unknown, message: "transport error", source: Some(tonic::transport::Error(Transport, hyper::Error(Io, Kind(ConnectionReset)))) }},
);
T2->ok($classify->($reset), 'connection-reset transport error is tolerable');

# A bare "transport error" bridge failure (no status struct) is still a
# shutdown-time teardown artifact — tolerate it.
my $transport = Temporalio::Exception::Bridge->new(message => 'transport error');
T2->ok($classify->($transport), 'bare transport error is tolerable');

# A broken-pipe / connection-closed teardown is likewise tolerable.
my $closed = Temporalio::Exception::Bridge->new(
    message => 'error trying to connect: connection closed before message completed');
T2->ok($classify->($closed), 'connection-closed teardown is tolerable');

# core's worker_finalize_shutdown does Arc::try_unwrap on the core worker and
# expects exactly one strong reference. Under -j4 contention a Tokio poll task
# that still holds a worker-Arc clone may not have dropped by the time finalize
# runs, so try_unwrap fails with "Cannot finalize, expected 1 reference, got N".
# The worker is being torn down regardless; this is a benign teardown race, not
# a shutdown bug, so it must be tolerated. (Reproduced verbatim from
# signals_queries.t stderr under prove -lj4.)
my $finalize_race = Temporalio::Exception::Bridge->new(
    message => 'Cannot finalize, expected 1 reference, got 2');
T2->ok($classify->($finalize_race),
    'finalize Arc-refcount race (expected 1 reference, got 2) is tolerable');

# The same race with a higher residual count is equally benign.
my $finalize_race3 = Temporalio::Exception::Bridge->new(
    message => 'Cannot finalize, expected 1 reference, got 3');
T2->ok($classify->($finalize_race3),
    'finalize race with got 3 is tolerable');

# A genuine bridge error unrelated to connection teardown must NOT be
# swallowed — it has to surface so real shutdown bugs are not hidden.
my $real = Temporalio::Exception::Bridge->new(
    message => 'worker has already been initiated');
T2->ok(!$classify->($real), 'an unrelated bridge error is NOT tolerated');

# A non-bridge exception (anything that is not a transport teardown) must never
# be tolerated, even if its text mentions transport.
my $other = Temporalio::Exception::Runtime->new(message => 'transport error');
T2->ok(!$classify->($other), 'a non-Bridge exception is NOT tolerated');

# Undef / plain-string defensiveness: never tolerate something we cannot
# positively classify as a bridge transport teardown.
T2->ok(!$classify->(undef), 'undef is not tolerated');
T2->ok(!$classify->('transport error'), 'a plain string is not tolerated');

T2->done_testing;
