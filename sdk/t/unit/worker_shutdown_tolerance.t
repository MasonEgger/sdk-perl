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
