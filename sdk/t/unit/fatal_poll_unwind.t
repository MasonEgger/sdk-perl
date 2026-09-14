# ABOUTME: Unit tests for the fatal poll-loop unwind (spec I3 and spec F3,
# ABOUTME: GitHub issue #3): Worker::run's private _await_loops_then_drain
# ABOUTME: gather must race the per-kind poll-loop futures on FIRST FAILURE,
# ABOUTME: not wait_all, and the DEAD loop's queue must then be drained with
# ABOUTME: failed "Worker shutting down" completions until core returns the
# ABOUTME: shutdown sentinel (no live worker/server needed: the poll/complete
# ABOUTME: bridge methods are replaced with synthetic Future doubles).
use v5.38;
use warnings;
use utf8;
use feature 'class';
no warnings 'experimental::class';
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Future ();
use IO::Async::Loop ();
use Temporalio::Core::Proto ();
use Temporalio::Worker ();
use Temporalio::Worker::PollLoop ();

# Code trace (spec I3 / GitHub #3): pre-fix, Worker::run drove
# `await Future->wait_all(@loops)` over the activity/workflow/Nexus
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
    field $runtime   :param = undef;    # only the run() subtest needs one
    method namespace { $namespace }
    method identity  { $identity }
    method runtime   { $runtime }
}

# run() reads $runtime->loop when it constructs the per-kind PollLoops. The
# loops never schedule anything on it here (every poll double resolves
# immediately), so a bare IO::Async::Loop is enough.
class FakeRuntime {
    field $loop :param;
    method loop { $loop }
}

# Stands in for ActivityDispatcher / WorkflowDispatcher: run() only calls
# notify_shutdown on it, because every poll double fails or returns the
# sentinel before a task is ever dispatched.
class FakeDispatcher {
    field $notified = 0;
    method notify_shutdown { $notified++; return }
    method notified        { $notified }
    method dispatch_task ($bytes) { return Future->done }
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

# --- spec F3 (GitHub issue #3): drain the DEAD loop's queue ----------------
#
# Python contract (../sdk-python worker/_worker.py:843-846): once
# initiate_shutdown has been sent, every per-kind worker whose task already
# finished WITH an exception has that task replaced by
# `worker.drain_poll_queue()`. Each kind's drain keeps polling and answers
# every task it receives with a failed completion carrying the failure message
# "Worker shutting down", returning only on PollShutdownError (the Perl poll
# sources' undef sentinel):
#
#   _activity.py:190-201  ActivityTaskCompletion.result.failed.failure.message
#   _workflow.py:231-242  WorkflowActivationCompletion.failed.failure.message
#   _nexus.py:198-209     NexusTaskCompletion.error.failure.message
#
# Only then does Python wait for every task (_worker.py:857), wait for the
# in-flight bodies (wait_all_completed, :869), and finalize (:875). Without the
# drain, core's Worker::shutdown (../sdk-rust
# crates/sdk-core/src/worker/mod.rs:967-1000) never finishes: with
# ignore_evicts_on_shutdown unset (Perl never sets it) it waits for every
# pending eviction to be both polled AND replied to, and for every in-flight
# activity body, so the dead loop's unpolled queue leaves core waiting on
# replies nobody will send.

my %POLL_METHOD = (
    activity => '_poll_activity_task',
    workflow => '_poll_workflow_activation',
    nexus    => '_poll_nexus_task',
);
my %COMPLETE_METHOD = (
    activity => '_complete_activity_task',
    workflow => '_complete_workflow_activation',
    nexus    => '_complete_nexus_task',
);

# Replace one kind's bridge poll/complete pair with doubles. @task_bytes is the
# queue core still holds for the dead loop; once it empties, the poll resolves
# to undef, which is how the SDK spells core's PollShutdownError. $fail_first
# makes the very first poll die instead, which is how a loop becomes the dead
# one in the first place, and fail_at => { N => $err } fails the Nth poll, which
# is how the DRAIN's own poll is made to die. Returns a handle with the captured
# completion bytes, a poll counter, and a restore closure.
sub patch_kind ($kind, %opt) {
    my @queue      = @{ $opt{tasks} // [] };
    my $fail_first = $opt{fail_first};
    my %fail_at    = %{ $opt{fail_at} // {} };
    my @sent;
    my $polls = 0;
    my $poll_name     = "Temporalio::Worker::$POLL_METHOD{$kind}";
    my $complete_name = "Temporalio::Worker::$COMPLETE_METHOD{$kind}";
    no strict 'refs';       ## no critic
    no warnings 'redefine';
    my $orig_poll     = \&{$poll_name};
    my $orig_complete = \&{$complete_name};
    *{$poll_name} = sub ($self) {
        $polls++;
        return Future->fail($fail_at{$polls}) if defined $fail_at{$polls};
        return Future->fail($fail_first) if defined $fail_first && $polls == 1;
        return Future->done(shift @queue);
    };
    *{$complete_name} = sub ($self, $bytes) {
        push @sent, $bytes;
        return Future->done;
    };
    return {
        sent    => \@sent,
        polls   => \$polls,
        restore => sub {
            no strict 'refs';    ## no critic
            no warnings 'redefine';
            *{$poll_name}     = $orig_poll;
            *{$complete_name} = $orig_complete;
            return;
        },
    };
}

T2->subtest(
    'activity drain: every queued task gets a failed "Worker shutting down" completion'
    => sub {
        my $ActivityTask = Temporalio::Core::Proto::resolve(
            'coresdk.activity_task.ActivityTask');
        my $Completion = Temporalio::Core::Proto::resolve(
            'coresdk.ActivityTaskCompletion');

        my $patch = patch_kind(activity => tasks => [
            $ActivityTask->new({ task_token => 'tok-1' })->encode,
            $ActivityTask->new({ task_token => 'tok-2' })->encode,
        ]);

        my $worker = build_worker();
        my $drain  = $worker->_drain_poll_queue('activity');
        T2->ok($drain->is_ready, 'the drain runs to the sentinel and returns');
        T2->ok(!$drain->is_failed, 'the drain itself never fails');

        my @sent = @{ $patch->{sent} };
        T2->is(scalar @sent, 2, 'both queued tasks were completed');
        my @tokens;
        for my $bytes (@sent) {
            my $c = $Completion->decode($bytes);
            push @tokens, $c->task_token;
            T2->is($c->result->failed->failure->message, 'Worker shutting down',
                'completion is a FAILED result with Python\'s drain message'
              . ' (_activity.py:198)');
        }
        T2->is(\@tokens, ['tok-1', 'tok-2'],
            'each completion echoes the polled task_token');
        T2->is(${ $patch->{polls} }, 3,
            'polling continued until the shutdown sentinel (2 tasks + 1 undef)');

        $patch->{restore}->();
    },
);

T2->subtest(
    'workflow drain: the cached run is answered with a failed activation completion'
    => sub {
        my $Activation = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_activation.WorkflowActivation');
        my $Completion = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_completion.WorkflowActivationCompletion');

        # This is the eviction shape core sends during shutdown: it must be
        # replied to, or Worker::shutdown never returns.
        my $patch = patch_kind(workflow => tasks => [
            $Activation->new({ run_id => 'run-abc' })->encode,
        ]);

        my $worker = build_worker();
        my $drain  = $worker->_drain_poll_queue('workflow');
        T2->ok($drain->is_ready, 'the workflow drain returns on the sentinel');

        my @sent = @{ $patch->{sent} };
        T2->is(scalar @sent, 1, 'the pending activation was completed');
        my $c = $Completion->decode($sent[0]);
        T2->is($c->run_id, 'run-abc',
            'the completion carries the activation\'s run_id'
          . ' (_workflow.py:236-238)');
        T2->is($c->failed->failure->message, 'Worker shutting down',
            'the completion is the FAILED variant with the drain message');

        $patch->{restore}->();
    },
);

T2->subtest(
    'nexus drain: both variants are answered, and a cancel keeps its own token'
    => sub {
        my $NexusTask = Temporalio::Core::Proto::resolve(
            'coresdk.nexus.NexusTask');
        my $CancelTask = Temporalio::Core::Proto::resolve(
            'coresdk.nexus.CancelNexusTask');
        my $PollResponse = Temporalio::Core::Proto::resolve(
            'temporal.api.workflowservice.v1.PollNexusTaskQueueResponse');
        my $Completion = Temporalio::Core::Proto::resolve(
            'coresdk.nexus.NexusTaskCompletion');

        # The two NexusTask oneof variants core can still have queued: a real
        # polled task, and a CancelNexusTask (nexus.proto:43-59). The cancel
        # carries its OWN task_token; Python reads task.task.task_token
        # unconditionally (_nexus.py:203-207), which answers a cancel with an
        # empty token, so the Perl drain reads the variant that is set.
        my $patch = patch_kind(nexus => tasks => [
            $NexusTask->new({
                task => $PollResponse->new({ task_token => 'ntok-1' }),
            })->encode,
            $NexusTask->new({
                cancel_task => $CancelTask->new({ task_token => 'ntok-2' }),
            })->encode,
        ]);

        my $worker = build_worker();
        my $drain  = $worker->_drain_poll_queue('nexus');
        T2->ok($drain->is_ready, 'the nexus drain returns on the sentinel');
        T2->ok(!$drain->is_failed,
            'the nexus drain itself never fails (a cancel variant does not'
          . ' blow up the token read)');

        my @sent = @{ $patch->{sent} };
        T2->is(scalar @sent, 2, 'both queued nexus tasks were completed');
        my @tokens;
        for my $bytes (@sent) {
            my $c = $Completion->decode($bytes);
            push @tokens, $c->task_token;
            T2->is($c->error->failure->message, 'Worker shutting down',
                'completion is the HandlerError variant with Python\'s drain'
              . ' message (_nexus.py:203-207)');
        }
        T2->is(\@tokens, ['ntok-1', 'ntok-2'],
            'the polled task echoes its token AND the cancel echoes its own:'
          . ' reading the wrong variant would leave the second one empty');
        T2->is(${ $patch->{polls} }, 3,
            'polling continued until the shutdown sentinel (2 tasks + 1 undef)');

        $patch->{restore}->();
    },
);

T2->subtest(
    'drain is guarded per kind: a second drain for the same kind polls nothing'
    => sub {
        my $patch  = patch_kind(activity => tasks => []);
        my $worker = build_worker();

        my $first = $worker->_drain_poll_queue('activity');
        T2->ok($first->is_ready, 'the first drain returns');
        T2->is(${ $patch->{polls} }, 1,
            'the first drain polled once and saw the sentinel');

        my $second = $worker->_drain_poll_queue('activity');
        T2->ok($second->is_ready, 'the second drain returns immediately');
        T2->is(${ $patch->{polls} }, 1,
            'the second drain issued NO poll: one drain per kind, ever'
          . ' (a double drain would steal tasks from the first)');

        $patch->{restore}->();
    },
);

T2->subtest(
    'PollLoop::drain_in_flight awaits dispatches left running when the poll source dies'
    => sub {
        my $dispatched = Future->new;
        my $poll_count = 0;
        my $loop_obj   = Temporalio::Worker::PollLoop->new(
            dispatcher  => FakeDispatcher->new,
            poll_source => sub {
                $poll_count++;
                return Future->done('task-bytes') if $poll_count == 1;
                return Future->fail("F3 injected poll-source death\n");
            },
        );

        # A dispatcher whose dispatch_task stays pending: the loop pushes it
        # onto @in_flight, then the next poll dies, so run() unwinds WITHOUT
        # reaching its own in-flight drain (PollLoop.pm run, the `last unless
        # defined $bytes` path). Those dispatches are the ones core's
        # at_task_mgr.shutdown is waiting on.
        no warnings 'redefine';
        local *FakeDispatcher::dispatch_task = sub ($self, $bytes) {
            return $dispatched;
        };

        my $run_f = $loop_obj->run;
        T2->ok($run_f->is_failed, 'run() propagates the poll-source death');

        my $drain = $loop_obj->drain_in_flight;
        T2->ok(!$drain->is_ready,
            'drain_in_flight is pending while a dispatch is still running');
        $dispatched->done;
        T2->ok($drain->is_ready,
            'drain_in_flight settles once the dispatch finishes'
          . ' (Python wait_all_completed, _worker.py:869)');
    },
);

T2->subtest(
    'two loops failing in the same tick: one drain per kind, a single raised error'
    => sub {
        my $ActivityTask = Temporalio::Core::Proto::resolve(
            'coresdk.activity_task.ActivityTask');
        my $Activation = Temporalio::Core::Proto::resolve(
            'coresdk.workflow_activation.WorkflowActivation');

        my $act_patch = patch_kind(activity =>
            fail_first => "F3 injected activity poll failure\n",
            tasks      => [ $ActivityTask->new({ task_token => 'a1' })->encode ],
        );
        my $wf_patch = patch_kind(workflow =>
            fail_first => "F3 injected workflow poll failure\n",
            tasks      => [ $Activation->new({ run_id => 'r1' })->encode ],
        );

        my $io_loop = IO::Async::Loop->new;
        my $worker  = Temporalio::Worker->new(
            client     => FakeClient->new(
                runtime => FakeRuntime->new(loop => $io_loop)),
            task_queue => 'demo',
        );

        my $finalized = 0;
        no warnings 'redefine';
        local *Temporalio::Worker::validate = sub ($self) { Future->done };
        local *Temporalio::Worker::_build_activity_dispatcher =
            sub ($self) { FakeDispatcher->new };
        local *Temporalio::Worker::_build_workflow_dispatcher =
            sub ($self) { FakeDispatcher->new };
        local *Temporalio::Worker::_finalize_and_free =
            sub ($self) { $finalized++; Future->done };

        my $run_f = $worker->run;
        $io_loop->await(Future->wait_any(
            $run_f->without_cancel,
            $io_loop->timeout_future(after => 20),
        ));
        T2->ok($run_f->is_ready,
            'run() unwinds when BOTH loops die in the same tick');
        T2->ok($run_f->is_failed, 'run() fails');

        my ($err) = $run_f->failure;
        T2->like($err, qr/F3 injected activity poll failure/,
            'the FIRST loop failure is the raised error');
        T2->unlike($err, qr/F3 injected workflow poll failure/,
            'the second simultaneous failure is not folded into it: one'
          . ' raised error');
        T2->unlike($err, qr/Cannot finalize/,
            'no secondary finalize error: the drain kept finalize unblocked');

        T2->is($finalized, 1, 'finalize was reached exactly once');
        T2->is(scalar @{ $act_patch->{sent} }, 1,
            'the activity drain completed the task core still held');
        T2->is(scalar @{ $wf_patch->{sent} }, 1,
            'the workflow drain completed the activation core still held');
        T2->is(${ $act_patch->{polls} }, 3,
            'activity kind polled once (fatally) then drained: 1 task + 1'
          . ' sentinel, one drain only');
        T2->is(${ $wf_patch->{polls} }, 3,
            'workflow kind polled once (fatally) then drained: 1 task + 1'
          . ' sentinel, one drain only');

        $act_patch->{restore}->();
        $wf_patch->{restore}->();
    },
);

T2->subtest(
    'a drain that dies is warned about and never displaces the loop error'
    => sub {
        # The activity loop dies on its first poll (so its kind gets a drain),
        # and the drain's own first poll then dies with something that is NOT
        # the shutdown sentinel. run() must still raise the ORIGINAL loop
        # error, and the drain's death must reach stderr rather than vanish:
        # a drain that stopped early can wedge finalize, and the warning is
        # the only record of why.
        my $act_patch = patch_kind(activity =>
            fail_first => "F3 injected activity poll failure\n",
            fail_at    => { 2 => "F3 injected drain poll failure\n" },
        );
        # The workflow loop sees the sentinel on its first poll and drains
        # cleanly, so it is a survivor and is never drained.
        my $wf_patch = patch_kind(workflow => tasks => []);

        my $io_loop = IO::Async::Loop->new;
        my $worker  = Temporalio::Worker->new(
            client     => FakeClient->new(
                runtime => FakeRuntime->new(loop => $io_loop)),
            task_queue => 'demo',
        );

        no warnings 'redefine';
        local *Temporalio::Worker::validate = sub ($self) { Future->done };
        local *Temporalio::Worker::_build_activity_dispatcher =
            sub ($self) { FakeDispatcher->new };
        local *Temporalio::Worker::_build_workflow_dispatcher =
            sub ($self) { FakeDispatcher->new };
        local *Temporalio::Worker::_finalize_and_free =
            sub ($self) { Future->done };

        # The handler is localized in a plain (non-async) block that stays on
        # the stack for the whole $io_loop->await, so it is in force while
        # run() is suspended, and it is off again before the assertions below.
        my @warnings;
        my $run_f;
        {
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            $run_f = $worker->run;
            $io_loop->await(Future->wait_any(
                $run_f->without_cancel,
                $io_loop->timeout_future(after => 20),
            ));
        }

        T2->ok($run_f->is_ready, 'run() unwinds even though the drain died');
        T2->ok($run_f->is_failed, 'run() fails');
        my ($err) = $run_f->failure;
        T2->like($err, qr/F3 injected activity poll failure/,
            'the ORIGINAL poll-loop error is what run() raises');
        T2->unlike($err, qr/F3 injected drain poll failure/,
            'the drain death did not replace or attach to it');

        my @drain_warnings =
            grep { /drain died/ } @warnings;
        T2->is(scalar @drain_warnings, 1,
            'exactly one drain-death warning was emitted');
        T2->like($drain_warnings[0],
            qr/^Temporalio::Worker: activity drain died: F3 injected drain poll failure\n$/,
            'the warning names the kind and carries the drain\'s own error');

        $act_patch->{restore}->();
        $wf_patch->{restore}->();
    },
);

T2->done_testing;
