# ABOUTME: Integration-test glue (P3.9) for driving a live worker: run the
# ABOUTME: worker's poll loops concurrently with a test body, then shut down and
# ABOUTME: drain cleanly. Keeps DevServer-backed tests free of boilerplate.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();

class Temporalio::Test::Worker {
    # The worker under test and the IO::Async loop its runtime drives.
    field $worker :param;
    field $loop   :param;

    # The worker's run future, started in ADJUST so the poll loops are live
    # before the test body awaits any workflow result.
    field $run_future;

    ADJUST {
        $run_future = $worker->run;
    }

    method worker { $worker }

    # await_result($future, $timeout=60) -> the resolved value. Awaits $future
    # while the worker's poll loops run concurrently. If the worker's run loop
    # crashes before $future resolves, that failure is surfaced (rather than the
    # test hanging until the timeout). A genuine timeout dies with a clear
    # message. The worker run future is protected from cancellation so awaiting a
    # result never tears the running worker down.
    method await_result ($future, $timeout = 60) {
        $loop->await(Future->wait_any(
            $future,
            $run_future->without_cancel,
            $loop->timeout_future(after => $timeout),
        ));
        if ($run_future->is_ready && $run_future->is_failed && !$future->is_ready)
        {
            die 'worker run loop failed: ' . (($run_future->failure)[0] // '');
        }
        die "future did not resolve within ${timeout}s\n"
            unless $future->is_ready;
        return $future->get;
    }

    # shutdown($timeout=60): initiate worker shutdown so the poll loops drain on
    # the ShutDown sentinel, then await the run future so finalize + free + fork
    # pool teardown all complete (no orphaned processes). Idempotent.
    method shutdown ($timeout = 60) {
        $worker->shutdown;
        $loop->await(Future->wait_any(
            $run_future, $loop->timeout_future(after => $timeout)));
        die "worker run did not drain within ${timeout}s\n"
            unless $run_future->is_ready;
        return;
    }
}

1;

__END__

=head1 NAME

Temporalio::Test::Worker - drive a live worker from an integration test

=head1 SYNOPSIS

    use Temporalio::Test::Worker ();

    my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

    my $handle = $tw->await_result($client->start_workflow(...));
    my $result = $tw->await_result($handle->result);

    $tw->shutdown;   # initiate -> drain -> finalize -> free; reaps fork pool

=head1 DESCRIPTION

Test-only glue (spec section 11, P3.9) for DevServer-backed integration tests
that need a running worker. Constructing one starts the worker's
C<run> poll loops; C<await_result> awaits a future (a workflow start, a
workflow result, ...) while the loops run concurrently, surfacing a worker-loop
crash promptly instead of hanging; C<shutdown> tears the worker down cleanly.

This lives under C<Temporalio::Test::> alongside
L<Temporalio::Test::DevServer> and L<Temporalio::Test::WorkflowReplay> — author
glue, not part of the public SDK surface.

=cut
