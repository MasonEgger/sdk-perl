# ABOUTME: Unit tests for the fatal poll-loop unwind (spec I3, GitHub issue #3):
# ABOUTME: Worker::run's private _await_loops_then_drain gather must race the
# ABOUTME: per-kind poll-loop futures on FIRST FAILURE, not wait_all, so one
# ABOUTME: fatal loop does not block forever on a healthy sibling that never
# ABOUTME: resolves (no live worker/server needed: synthetic Future doubles).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use Temporalio::Worker ();

# Code trace (spec I3 / GitHub #3): pre-fix, Worker::run (Worker.pm:571) drives
# `await Future->wait_all(@loops)` (:615) over the activity/workflow/Nexus
# poll-loop futures. wait_all settles only once EVERY component future is
# ready, so a fatally-dying loop cannot make run() return while a healthy
# sibling is still polling with no work (which, against a live server with an
# idle task queue, can block indefinitely). Python composes the analogous
# gather with `asyncio.wait(tasks, return_when=FIRST_EXCEPTION)`
# (../sdk-python worker/_worker.py:812): the wait resolves as soon as ANY task
# raises, without waiting for the others. _await_loops_then_drain is the Perl
# equivalent: a first-failure race that still waits for every loop to drain on
# the clean path (verified below).
#
# Same construction-only fake as worker_new.t: the Worker reads namespace off
# the client but this test never touches core, FFI, or a live connection;
# _await_loops_then_drain only manipulates the Future objects it is handed.
class FakeClient {
    field $namespace :param = 'default';
    field $identity  :param = 'pid@host';
    method namespace { $namespace }
    method identity  { $identity }
}

sub build_worker () {
    return Temporalio::Worker->new(
        client     => FakeClient->new,
        task_queue => 'demo',
    );
}

T2->subtest(
    'first-failure race: a fatal loop settles the gather without waiting for a never-resolving sibling'
    => sub {
        my $worker    = build_worker();
        my $activity_f = Future->new;
        my $workflow_f = Future->new;    # the "healthy sibling" (never settles)

        my $gather = $worker->_await_loops_then_drain($activity_f, $workflow_f);
        T2->ok(!$gather->is_ready,
            'gather is pending before either loop settles');

        $activity_f->fail("I3 injected poll-loop failure\n");

        # No IO::Async loop, no timeout, no sleep: Future::on_ready fires
        # synchronously on ->fail, so the race settling here (still inside
        # this synchronous test body, with $workflow_f left untouched and
        # pending) is itself the bounded proof that the gather does not block
        # on the healthy sibling.
        T2->ok($gather->is_ready,
            'gather settles as soon as the FIRST loop fails');
        T2->ok(!$workflow_f->is_ready,
            'the healthy sibling is untouched (still pending): the fix races'
          . ' failure detection, it does not cancel siblings itself');

        my ($error) = $gather->get;
        T2->like($error, qr/I3 injected poll-loop failure/,
            'the gather carries the failing loop\'s error');
    },
);

T2->subtest(
    'healthy path: with no failure, the gather returns only after ALL loops drain'
    => sub {
        my $worker      = build_worker();
        my $activity_f  = Future->new;
        my $workflow_f  = Future->new;

        my $gather = $worker->_await_loops_then_drain($activity_f, $workflow_f);
        T2->ok(!$gather->is_ready, 'gather pending before either loop drains');

        $activity_f->done;
        T2->ok(!$gather->is_ready,
            'gather does NOT return prematurely after only one loop drains'
          . ' cleanly');

        $workflow_f->done;
        T2->ok($gather->is_ready,
            'gather returns once the LAST loop drains');
        my ($error) = $gather->get;
        T2->ok(!defined $error, 'no error on the all-clean path');
    },
);

T2->subtest(
    'a Nexus-loop-shaped third future participates in the same race'
    => sub {
        my $worker     = build_worker();
        my $activity_f = Future->new;
        my $workflow_f = Future->new;
        my $nexus_f    = Future->new;

        my $gather = $worker->_await_loops_then_drain(
            $activity_f, $workflow_f, $nexus_f);
        $nexus_f->fail("I3 injected Nexus poll-loop failure\n");

        T2->ok($gather->is_ready,
            'a third (Nexus) loop failing also settles the gather immediately');
        T2->ok(!$activity_f->is_ready && !$workflow_f->is_ready,
            'the other two healthy siblings remain untouched');
    },
);

T2->done_testing;
