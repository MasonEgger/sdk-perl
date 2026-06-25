# ABOUTME: Unit tests for Temporalio::Test::Worker::await_idempotent (P10.0.5):
# ABOUTME: bounded retry around transient RpcTimeout on idempotent reads only.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Scalar::Util ();
use IO::Async::Loop ();
use Temporalio::Test::Worker ();
use Temporalio::Exception::RpcTimeout ();
use Temporalio::Exception::RpcError ();
use Temporalio::Exception::WorkflowAlreadyStarted ();

# A stand-in worker: Test::Worker only calls ->run on it (in ADJUST) and reads
# the resulting future via without_cancel. A never-resolving future keeps the
# "run loop" alive so await_result/await_idempotent only resolve on the body
# future, exactly as a live worker behaves while a query is in flight.
package FakeWorker {
    sub new { bless {}, shift }
    sub run { return Future->new }    # never resolves; never fails
}

my $loop = IO::Async::Loop->new;
my $tw   = Temporalio::Test::Worker->new(worker => FakeWorker->new, loop => $loop);

# await_idempotent exists and re-invokes the producer per attempt.
my $producer = $tw->can('await_idempotent');
T2->ok($producer, 'await_idempotent is defined');

T2->subtest('returns the value on first success, calling the producer once' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->done('ok');
    });
    T2->is($value, 'ok', 'resolved value is returned');
    T2->is($calls, 1, 'producer called exactly once when it succeeds');
});

T2->subtest('retries on a transient RpcTimeout, then succeeds' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcTimeout->new(
            message => 'Timeout expired', status_name => 'DEADLINE_EXCEEDED'))
            if $calls < 3;
        return Future->done('late');
    }, attempts => 3, backoff => 0);
    T2->is($value, 'late', 'succeeds once the timeout clears');
    T2->is($calls, 3, 'producer retried up to the third attempt');
});

T2->subtest('rethrows RpcTimeout after attempts are exhausted' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            $tw->await_idempotent(sub {
                $calls++;
                return Future->fail(Temporalio::Exception::RpcTimeout->new(
                    message => 'Timeout expired'));
            }, attempts => 2, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcTimeout'),
        'the RpcTimeout surfaces after the last attempt',
    );
    T2->is($calls, 2, 'producer called exactly attempts times');
});

T2->subtest('does NOT retry a non-transient RpcError (NOT_FOUND)' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            $tw->await_idempotent(sub {
                $calls++;
                return Future->fail(Temporalio::Exception::RpcError->new(
                    message => 'not found',
                    status_code => 5, status_name => 'NOT_FOUND'));
            }, attempts => 5, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcError')
            && !$err->isa('Temporalio::Exception::RpcTimeout'),
        'a non-transient RpcError is raised immediately',
    );
    T2->is($calls, 1, 'a non-transient error is not retried');
});

# Transient transport hiccups under load surface NOT as RpcTimeout but as a
# bare RpcError: UNAVAILABLE (gRPC 14), or the catch-all with an h2/transport
# message ("h2 protocol error: http2 error", connection reset, broken pipe).
# These are the same load artifact as DEADLINE_EXCEEDED and must retry on an
# idempotent read.
T2->subtest('retries a transient UNAVAILABLE RpcError, then succeeds' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcError->new(
            message => 'unavailable',
            status_code => 14, status_name => 'UNAVAILABLE'))
            if $calls < 2;
        return Future->done('back');
    }, attempts => 3, backoff => 0);
    T2->is($value, 'back', 'succeeds once the transport recovers');
    T2->is($calls, 2, 'UNAVAILABLE was retried');
});

T2->subtest('retries a transient h2/transport-message RpcError' => sub {
    my $calls = 0;
    my $value = $tw->await_idempotent(sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcError->new(
            message => 'h2 protocol error: http2 error'))
            if $calls < 2;
        return Future->done('back');
    }, attempts => 3, backoff => 0);
    T2->is($value, 'back', 'succeeds once the h2 hiccup clears');
    T2->is($calls, 2, 'an h2 transport error was retried');
});

# P10.0.6: the SAME classifier must also recognize the dev-server CONNECT race.
# An ephemeral dev server that has started but not yet bound/accepted makes the
# bridge surface "Connection failed: ...Failed connecting to test server after 5
# seconds, last error: ...ConnectionRefused..." (or a bare "tcp connect error"
# / "connection refused" / "UNAVAILABLE" / "TonicTransportError"). These are the
# transient connect-time twin of the load-stall transport faults and must be
# retried by a resilient connect. Genuine connect failures (a TLS-mismatch
# "Connection failed: ...handshake..." or any other RpcError) are NOT transient
# and must surface at once.
my $classifier = Temporalio::Test::Worker->can('_is_transient_load_error');
T2->ok($classifier, '_is_transient_load_error is callable as a sub');

T2->subtest('classifier matches the dev-server connect-race shapes' => sub {
    my @transient = (
        'Connection failed: tonic::transport::Error(Transport, '
            . 'ConnectionRefused, ...)',
        'Connection failed: Failed connecting to test server after 5 seconds, '
            . 'last error: Some(Status { ... ConnectionRefused ... })',
        'tcp connect error: Connection refused (os error 111)',
        'transport error: connection refused',
        'TonicTransportError: error trying to connect',
    );
    for my $msg (@transient) {
        my $err = Temporalio::Exception::RpcError->new(message => $msg);
        T2->ok($classifier->($err),
            "transient connect shape is retried: $msg");
    }

    # A bare UNAVAILABLE on connect is already covered, but assert it stays so.
    T2->ok(
        $classifier->(Temporalio::Exception::RpcError->new(
            message => 'unavailable', status_name => 'UNAVAILABLE')),
        'UNAVAILABLE on connect is transient',
    );
});

# P10.0.6 (run7/run9 mode): a clean DEADLINE_EXCEEDED ("Timeout expired") on a
# non-idempotent start_workflow / signal / terminate must NOT be left to surface
# raw on a starved box. await_with_retry retries the transient timeout, and
# tolerates a WorkflowAlreadyStarted on a start retry (proof the prior attempt's
# RPC reached the server) by returning the value its on_already_started callback
# yields. A real, non-transient failure still surfaces at once.
T2->ok($tw->can('await_with_retry'), 'await_with_retry is defined');

T2->subtest('await_with_retry retries a transient Timeout, then succeeds' => sub {
    my $calls = 0;
    my $value = $tw->await_with_retry(sub {
        $calls++;
        return Future->fail(Temporalio::Exception::RpcTimeout->new(
            message => 'Timeout expired')) if $calls < 3;
        return Future->done('started');
    }, attempts => 5, backoff => 0);
    T2->is($value, 'started', 'succeeds once the timeout clears');
    T2->is($calls, 3, 'the non-idempotent op was retried past the timeout');
});

T2->subtest('await_with_retry surfaces a non-transient failure at once' => sub {
    my $calls = 0;
    my $err = do {
        local $@;
        eval {
            $tw->await_with_retry(sub {
                $calls++;
                return Future->fail(Temporalio::Exception::RpcError->new(
                    message => 'invalid', status_code => 3,
                    status_name => 'INVALID_ARGUMENT'));
            }, attempts => 5, backoff => 0);
            1;
        } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::RpcError'),
        'a non-transient error raises immediately',
    );
    T2->is($calls, 1, 'a non-transient op is not retried');
});

# start_workflow_with_retry centralizes the unique-id start: a retry that hits
# WorkflowAlreadyStarted re-fetches the handle via get_workflow_handle.
T2->ok($tw->can('start_workflow_with_retry'),
    'start_workflow_with_retry is defined');

T2->subtest('start_workflow_with_retry re-fetches on WorkflowAlreadyStarted' => sub {
    my $start_calls = 0;
    my $fetch_calls = 0;
    package FakeStartClient {
        sub new { bless { t => $_[1] }, $_[0] }
        sub start_workflow {
            my ($self, $type, $args, %o) = @_;
            $self->{t}->{start}->($type, $args, %o);
        }
        sub get_workflow_handle {
            my ($self, $id) = @_;
            $self->{t}->{fetch}->($id);
        }
    }
    my $client = FakeStartClient->new({
        start => sub {
            $start_calls++;
            return Future->fail(Temporalio::Exception::RpcTimeout->new(
                message => 'Timeout expired')) if $start_calls == 1;
            return Future->fail(
                Temporalio::Exception::WorkflowAlreadyStarted->new(
                    message => 'already started', workflow_id => 'wf-1',
                    workflow_type => 'W'));
        },
        fetch => sub { $fetch_calls++; return "HANDLE:$_[0]" },
    });
    my $handle = $tw->start_workflow_with_retry(
        $client, 'W', [], id => 'wf-1', task_queue => 'tq', backoff => 0);
    T2->is($handle, 'HANDLE:wf-1', 're-fetched the existing handle');
    T2->is($start_calls, 2, 'start retried after the transient timeout');
    T2->is($fetch_calls, 1, 'handle re-fetched once on WorkflowAlreadyStarted');
});

T2->subtest('start_workflow_with_retry does not forward retry opts to start' => sub {
    my %seen_opts;
    package OptCaptureClient {
        sub new { bless { t => $_[1] }, $_[0] }
        sub start_workflow {
            my ($self, $type, $args, %o) = @_;
            $self->{t}->{cap}->(%o);
            return Future->done('H');
        }
        sub get_workflow_handle { return 'H' }
    }
    my $client = OptCaptureClient->new({ cap => sub { %seen_opts = @_ } });
    my $handle = $tw->start_workflow_with_retry(
        $client, 'W', [],
        id => 'wf-2', task_queue => 'tq',
        timeout => 7, attempts => 2, backoff => 0);
    T2->is($handle, 'H', 'handle returned');
    T2->ok(!exists $seen_opts{timeout}, 'timeout not forwarded to start_workflow');
    T2->ok(!exists $seen_opts{attempts}, 'attempts not forwarded');
    T2->ok(!exists $seen_opts{backoff}, 'backoff not forwarded');
    T2->is($seen_opts{id}, 'wf-2', 'id IS forwarded to start_workflow');
    T2->is($seen_opts{task_queue}, 'tq', 'task_queue IS forwarded');
});

T2->subtest('classifier does NOT match a genuine connect failure' => sub {
    # The TLS-against-non-TLS test (T-cli-connect-2) surfaces "Connection
    # failed: ...handshake/protocol..." — a real misconfiguration, never a race.
    my @genuine = (
        'Connection failed: tls handshake eof',
        'Connection failed: invalid certificate',
        'NotFound: workflow execution not found',
    );
    for my $msg (@genuine) {
        my $err = Temporalio::Exception::RpcError->new(message => $msg);
        T2->ok(!$classifier->($err),
            "genuine failure is NOT retried: $msg");
    }
});

T2->done_testing;
