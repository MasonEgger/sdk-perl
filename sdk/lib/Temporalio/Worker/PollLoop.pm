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
        my $dispatch_error;
        while (1) {
            my $bytes = await $poll_source->();
            last unless defined $bytes;
            # Dispatch concurrently: a slow activity must not block polling the
            # next task. Track the Future so shutdown can await it. The
            # dispatcher owns the die-to-failed-completion mapping (spec R11,
            # finding R5): dispatch_task resolves even when task processing
            # dies, because a FAILED completion is built and sent instead. A
            # dispatch Future that fails therefore means the completion
            # contract with core was broken (e.g. the completion could not be
            # sent at all) — that is surfaced by failing run(), never
            # warned-and-swallowed (the swallow left workflow tasks
            # uncompleted and the workflow wedged until timeout).
            push @in_flight, $dispatcher->dispatch_task($bytes);
            # Reap finished dispatches so the array does not grow unbounded,
            # capturing the first failure before it is dropped.
            for my $done (grep { $_->is_ready } @in_flight) {
                $dispatch_error //= ($done->failure)[0] if $done->is_failed;
            }
            @in_flight = grep { !$_->is_ready } @in_flight;
            last if defined $dispatch_error;
        }
        # Drain in-flight dispatches so pending completions are sent, then
        # surface any dispatch failure (wait_all itself never fails).
        await Future->wait_all(@in_flight) if @in_flight;
        for my $f (@in_flight) {
            $dispatch_error //= ($f->failure)[0] if $f->is_failed;
        }
        die $dispatch_error if defined $dispatch_error;
        return;
    }

    # drain_in_flight() (spec F3, GitHub issue #3): a Future that settles once
    # every dispatch this loop still has running has finished. run() awaits its
    # own @in_flight on the exit paths it controls, but a poll source that DIES
    # throws straight out of the while loop above, so those dispatches are left
    # un-awaited and their completions unsent. Core is waiting on exactly that
    # work (at_task_mgr::shutdown does not finish while an activity body is
    # outstanding), and the futures are cancelled the moment this object goes
    # away, so Worker::run calls this on the fatal unwind to let them settle
    # before _finalize_and_free. Mirrors Python's wait_all_completed
    # (../sdk-python worker/_worker.py:865-871). Never fails: wait_all cannot,
    # and a dispatch failure on this path is subordinate to the poll-source
    # death run() is already unwinding. Safe on a loop that never ran and safe
    # to call more than once.
    method drain_in_flight () {
        return Future->wait_all(@in_flight);
    }
}

1;

__END__

=encoding utf8

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

The generic poll loop, shared by the activity and workflow sides, of spec
section 8.4. C<run> awaits the injected C<poll_source> for the next task's
serialized bytes, exits on the C<undef> ShutDown sentinel, and otherwise hands
the bytes to the C<dispatcher>'s C<dispatch_task> method. Dispatches run
concurrently (a slow activity must not stall polling); the loop tracks the
in-flight Futures and awaits them before returning so pending completions are
sent. A dispatcher maps task-processing dies to failed completions itself
(spec R11), so a dispatch Future that fails means the completion contract with
core was broken; C<run> surfaces that by failing, after draining the remaining
in-flight dispatches — it is never warned-and-swallowed (finding R5: the
swallow left workflow tasks uncompleted and the workflow wedged until timeout).

A POLL SOURCE that dies is different: it throws out of the loop before that
in-flight drain is reached, so C<run> fails with dispatches still running.
C<drain_in_flight> exposes them to the caller, which is what
L<Temporalio::Worker>'s fatal unwind awaits before finalizing (spec F3).

Making the poll source injectable lets unit tests feed crafted C<ActivityTask>
protos (and the shutdown sentinel) without a live server; the worker supplies a
real source that issues C<worker_poll_activity_task> over the callback bridge.

=head1 CONSTRUCTOR

=head2 new

    my $obj = Temporalio::Worker::PollLoop->new(
        poll_source => ...,
        dispatcher => ...,
        loop => ...,
    );

Constructs a Temporalio::Worker::PollLoop. Named parameters:

=over 4

=item C<poll_source>

(required)

=item C<dispatcher>

(required)

=item C<loop>

(optional, default C<undef>)

=back

=head1 METHODS

=head2 dispatcher

Accessor returning the C<dispatcher> value.

=head2 drain_in_flight

    await $loop->drain_in_flight;

Returns a L<Future> that settles once every dispatch the loop still has running
has finished. C<run> already does this on the exit paths it controls, but a
poll source that dies throws out of the loop with those dispatches un-awaited;
L<Temporalio::Worker>'s fatal unwind calls this so their completions still
reach core before the worker is finalized (spec F3). Never fails.

=head2 poll_source

Accessor returning the C<poll_source> value.

=head2 run

Async. Drives the poll/complete loop for one task source, dispatching each polled task; returns a L<Future> that completes on shutdown.

=cut
