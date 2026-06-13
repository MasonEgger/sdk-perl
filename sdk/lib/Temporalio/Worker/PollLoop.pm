# ABOUTME: Generic poll->dispatch loop (spec section 8.4 / 8.3): awaits a poll
# ABOUTME: source for serialized task bytes, hands each to a dispatcher, and
# ABOUTME: returns on the null shutdown sentinel. The poll source is injectable
# ABOUTME: so unit tests feed crafted tasks without a live worker.
use v5.38;
use warnings;
use feature 'class';
no warnings 'experimental::class';

use Future ();
use Future::AsyncAwait;

class Temporalio::Worker::PollLoop {
    # A coderef () -> Future resolving to the next serialized task's bytes, or
    # undef on ShutDown. For the activity loop this wraps
    # Temporalio::Core::Callback->issue_async(worker_poll => ... poll_activity_task).
    field $poll_source :param;

    # An object with dispatch_task($bytes) -> Future. The loop fires-and-tracks
    # each dispatch concurrently (sdk-core already serializes per task token);
    # in-flight dispatches are awaited before the loop returns.
    field $dispatcher :param;

    # The IO::Async loop the dispatches run on (held for parity with the rest
    # of the worker; the loop itself does not schedule timers).
    field $loop :param = undef;

    field @in_flight;    # Futures for dispatches still running

    method poll_source { $poll_source }
    method dispatcher  { $dispatcher }

    # run() (spec section 8.4 steps 1-2): poll, branch on undef (exit), else
    # dispatch and loop. On the shutdown sentinel, wait for in-flight
    # dispatches to drain before returning so completions are sent (T-wkr-4:
    # shutdown mid-run returns once work drains; a never-started / already-empty
    # loop returns immediately).
    async method run () {
        while (1) {
            my $bytes = await $poll_source->();
            last unless defined $bytes;
            # Dispatch concurrently: a slow activity must not block polling the
            # next task. Track the Future so shutdown can await it. A failed
            # dispatch is logged, never fatal to the loop (spec section 8.4 —
            # a dispatch error must not crash the worker).
            my $f = $dispatcher->dispatch_task($bytes)
                ->else(sub ($err, @) {
                    warn "Temporalio::Worker::PollLoop: dispatch failed: $err\n";
                    return Future->done;
                });
            push @in_flight, $f;
            # Reap finished dispatches so the array does not grow unbounded.
            @in_flight = grep { !$_->is_ready } @in_flight;
        }
        await Future->wait_all(@in_flight) if @in_flight;
        return;
    }
}

1;

__END__

=head1 NAME

Temporalio::Worker::PollLoop - poll a task queue and dispatch tasks

=head1 SYNOPSIS

    use Temporalio::Worker::PollLoop ();

    my $loop = Temporalio::Worker::PollLoop->new(
        poll_source => sub { ... return Future resolving to $bytes-or-undef },
        dispatcher  => $activity_dispatcher,   # ->dispatch_task($bytes)
        loop        => $io_async_loop,
    );
    await $loop->run;     # returns when the poll source yields undef

=head1 DESCRIPTION

The generic activity (and, in a later phase, workflow) poll loop of spec
section 8.4. C<run> awaits the injected C<poll_source> for the next task's
serialized bytes, exits on the C<undef> ShutDown sentinel, and otherwise hands
the bytes to the C<dispatcher>'s C<dispatch_task> method. Dispatches run
concurrently (a slow activity must not stall polling); the loop tracks the
in-flight Futures and awaits them before returning so pending completions are
sent. A dispatch that fails is warned about and swallowed — a single bad task
never tears down the worker (spec section 8.4 failure modes).

Making the poll source injectable lets unit tests feed crafted C<ActivityTask>
protos (and the shutdown sentinel) without a live server; the worker supplies a
real source that issues C<worker_poll_activity_task> over the callback bridge.

=cut
