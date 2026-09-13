# ABOUTME: I3 + F3 (parity audit worker finding 3, GitHub issue #3) acceptance:
# ABOUTME: a fatal poll-loop death must unwind Worker::run organically (no test
# ABOUTME: code calling shutdown itself): run() returns the fatal error, the
# ABOUTME: healthy sibling loop is stopped via initiate_shutdown, the DEAD
# ABOUTME: loop's queue is drained so core's shutdown can finish, and finalize
# ABOUTME: attaches no secondary error. Subprocess-guarded because a pre-fix
# ABOUTME: failure can be a HANG (scenario 1) rather than a wrong answer.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Code trace (spec I3): pre-fix, Worker.pm run() gathered the per-kind poll
# loops with `await Future->wait_all(@loops)`, which settles only once EVERY
# loop is ready. The first scenario below kills the activity loop on its very
# first poll while the workflow loop keeps long-polling a live, otherwise-idle
# task queue with no shutdown ever requested: an organic, never-resolving
# healthy sibling, exactly the real-world trigger. (The R94 on_fatal_error test
# cannot exercise this: worker_initiate_shutdown is worker-wide, so calling
# $worker->shutdown up front (R94's technique) flips the sentinel for EVERY
# poll kind at once, which is why R94 passes even though the underlying
# wait_all gather never had to race anything.)
#
# Code trace (spec F3): racing to the first failure is only half the unwind.
# The failed loop stops polling ITS kind for good, and core's Worker::shutdown
# (../sdk-rust crates/sdk-core/src/worker/mod.rs:967-1000) does not finish
# until workflows.shutdown() has seen every pending eviction both POLLED and
# REPLIED TO (Perl never sets ignore_evicts_on_shutdown) and at_task_mgr.
# shutdown() has seen every in-flight activity body settle. So a dead workflow
# loop holding a CACHED run, or a dead activity loop with a body in flight,
# leaves core waiting on a reply the dead loop will never send. Python handles
# it by replacing the failed poller's task with drain_poll_queue (../sdk-python
# worker/_worker.py:843-846), which answers each remaining task with a failed
# "Worker shutting down" completion (_activity.py:190-201,
# _workflow.py:231-242, _nexus.py:198-209) until the poll reports shutdown, and
# by awaiting wait_all_completed (:869) before finalize_shutdown (:875). The
# second and third scenarios below are the live reproductions of those two
# unanswered replies, and neither one hangs against the pinned core. Scenario 2
# fails pre-fix on its completion-count assertion: run() does unwind, but the
# pending eviction is never answered, and core's workflow-processing thread
# panics with "Activation processor channel not dropped". Scenario 3 PASSED
# pre-fix, because the dead loop's orphaned dispatch keeps running on the IO
# loop while finalize awaits core; it is kept as a regression guard on the
# in-flight await. Every scenario still runs under the subprocess guard,
# because scenario 1 does hang pre-fix and any of the three could hang on a
# regression.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Modules are LOADED in the parent (FFI symbols attached), but nothing that
# starts sdk-core's Tokio threads runs here; the runtime is created only
# inside the forked child (SubprocessGuard requires this for a safe fork).
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Activity::FunctionDefinition;
require WfDef::QueryGreeter;
require WfDef::SignalGreeter;
require WfDef::ActivityCaller;
require SubprocessGuard;

# bounded($loop, $future, $secs, $what) -> the future's value. Runs the IO loop
# (so the worker under test keeps polling) until $future settles or the ceiling
# expires. without_cancel keeps $future PENDING on the timeout arm rather than
# letting wait_any cancel it into a ready-but-neither state (the Future 0.52
# loser semantics pinned by t/unit/future_semantics.t), so the guard below
# branches on the future's ACTUAL state.
sub bounded ($loop, $future, $secs, $what) {
    $loop->await(Future->wait_any(
        $future->without_cancel, $loop->timeout_future(after => $secs)));
    die "$what did not settle within ${secs}s\n" unless $future->is_ready;
    return $future->get;
}

# assert_unwound($loop, $run_f, $injected, $what): the shared post-conditions
# every scenario shares. run() must settle within the ceiling (a wedge is the
# pre-fix failure mode), fail with the INJECTED error rather than anything
# raised later on the way out, and carry no attached secondary: a secondary
# means _finalize_and_free itself failed, which is what an undrained poll queue
# produces once core's shutdown gives up.
sub assert_unwound ($loop, $run_f, $injected, $what) {
    $loop->await(Future->wait_any(
        $run_f->without_cancel, $loop->timeout_future(after => 60)));
    die "$what: run() did not unwind within 60s of the fatal poll-loop death"
      . " (the dead loop's queue is still undrained, F3 regression)\n"
        unless $run_f->is_ready;
    die "$what: run() did not FAIL: the injected fatal error was lost\n"
        unless $run_f->is_failed;
    my ($err) = $run_f->failure;
    die "$what: run() failed with '$err', not the injected poll-loop failure\n"
        unless "$err" =~ /\Q$injected\E/;
    die "$what: the fatal error carries an attached secondary ('$err'):"
      . " finalize failed on the way out\n"
        if "$err" =~ /also failed:|Cannot finalize/;
    return 1;
}

# Scenario 1 (spec I3): the activity loop dies on its first poll against an
# idle queue while the workflow loop long-polls with no work. Nothing is
# cached and nothing is in flight, so this isolates the first-failure race.
my $idle_queue_child = sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
    );

    my $client;
    my $cleanup = sub {
        local $@;
        eval { $client->connection->close if defined $client; 1 };
        eval { $server->shutdown; 1 };
    };

    my $verified = 0;
    my $ok = eval {
        $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
            Temporalio::Client->connect(
                $server->target,
                namespace => 'default',
                runtime   => $runtime,
            );
        });

        # Fire the REAL poll (so core's activity poller bookkeeping sees a
        # call was issued, the P2.2 lesson one level up: skipping the real
        # FFI call entirely leaves core waiting forever for a poller that
        # never started) but do not await it; hand the SDK-visible caller an
        # immediately-failed Future instead. The dangling real poll settles
        # later on its own once shutdown is eventually initiated; nothing
        # needs to collect that result. The injection is ONE-SHOT so the F3
        # drain, which reuses this same poll source, reaches the real bridge.
        my $injected = 'I3 injected poll-loop failure';
        my $fired    = 0;
        {
            no warnings 'redefine';
            my $orig = \&Temporalio::Worker::_poll_activity_task;
            *Temporalio::Worker::_poll_activity_task = sub ($self) {
                my $real = $orig->($self);
                return $real if $fired++;
                return Future->fail("$injected\n");
            };
        }

        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => "perl-sdk-i3-$$-" . int(rand(1_000_000)),
            workflows  => ['WfDef::QueryGreeter'],
        );

        my $run_f = $worker->run;
        assert_unwound($loop, $run_f, $injected, 'idle queue');

        # Post-run state (spec F3): the worker is spent. _assert_open is the
        # single gate, so a second run must refuse rather than re-enter a
        # freed core worker.
        # run() is an async method, so _assert_open's die surfaces as a
        # FAILED future rather than a synchronous throw; read both shapes.
        my $reran_text = do {
            local $@;
            my $rerun = eval { $worker->run };
            if    (!defined $rerun)   { "$@" }
            elsif ($rerun->is_failed) { ($rerun->failure)[0] // '' }
            else                      { $rerun->cancel; 'run() was accepted' }
        };
        die "idle queue: a second run() did not refuse: '$reran_text'\n"
            unless "$reran_text" =~ /Worker is shut down/;

        $verified = 1;
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

# Scenario 2 (spec F3): the workflow loop dies while core still owes an
# EVICTION on a run. max_cached_workflows => 0 makes that state deterministic:
# with no sticky cache core requests an eviction the instant a workflow task
# completes, and its shutdown does not finish until that eviction has been both
# polled and replied to (ignore_evicts_on_shutdown is false by default and the
# Perl SDK never sets it). The injection arms on the poll issued right after
# the first completion, so the eviction is queued with nobody left to take it.
#
# Observed pre-fix (2026-09-13, temporal CLI 1.6.2 / server 1.30.2): run()
# itself still unwinds, because the dead loop's orphaned dispatch keeps running
# on the IO loop while finalize awaits core. What does NOT happen is the
# eviction reply: exactly one workflow completion is ever sent, and core's
# workflow-processing thread panics with "Activation processor channel not
# dropped" as it tears down with the activation still outstanding. The count
# assertion below is therefore the RED signal, not a timeout.
#
# Post-fix the panic is replaced by a single core ERROR log, "No workflow task
# for run id ... found when trying to fail activation": an eviction activation
# has no workflow task to fail, and the drain answers it with the failed
# completion Python's drain_poll_queue also sends (_workflow.py:236-240). Core
# accepts it and finishes shutting down, so the line is expected output here.
my $pending_evict_child = sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
    );

    my $client;
    my $cleanup = sub {
        local $@;
        eval { $client->connection->close if defined $client; 1 };
        eval { $server->shutdown; 1 };
    };

    my $verified = 0;
    my $ok = eval {
        $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
            Temporalio::Client->connect(
                $server->target,
                namespace => 'default',
                runtime   => $runtime,
            );
        });

        my $injected    = 'F3 injected workflow poll failure';
        my $completions = 0;
        my $armed       = 0;
        {
            no warnings 'redefine';
            my $orig_poll = \&Temporalio::Worker::_poll_workflow_activation;
            my $orig_complete =
                \&Temporalio::Worker::_complete_workflow_activation;
            *Temporalio::Worker::_complete_workflow_activation =
                sub ($self, $bytes) {
                    $completions++;
                    return $orig_complete->($self, $bytes);
                };
            # One-shot, armed only once a full activation round trip has
            # completed: by then core has queued the eviction. Every later
            # call is the drain's, and must reach the real bridge poll.
            *Temporalio::Worker::_poll_workflow_activation = sub ($self) {
                if (!$armed && $completions > 0) {
                    $armed = 1;
                    return Future->fail("$injected\n");
                }
                return $orig_poll->($self);
            };
        }

        my $suffix     = "$$-" . int(rand(1_000_000));
        my $task_queue = "perl-sdk-f3-evict-$suffix";
        my $worker     = Temporalio::Worker->new(
            client               => $client,
            task_queue           => $task_queue,
            workflows            => ['WfDef::SignalGreeter'],
            max_cached_workflows => 0,
        );
        my $run_f = $worker->run;

        # SignalGreeter parks its :Run on a 60s timer, so the workflow task
        # completes (and the eviction is queued) while the run is very much
        # still alive server-side.
        bounded($loop,
            $client->start_workflow('SignalGreeter', [],
                id         => "perl-sdk-f3-evict-wf-$suffix",
                task_queue => $task_queue),
            30, 'start_workflow');

        assert_unwound($loop, $run_f, $injected, 'pending eviction');
        die "pending eviction: the injection never armed\n" unless $armed;
        die "pending eviction: only $completions workflow completion(s) were"
          . " sent, so the eviction core was waiting on was never answered"
          . " (the dead loop's queue is undrained, F3)\n"
            unless $completions >= 2;

        $verified = 1;
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

# Scenario 3 (spec F3): the activity loop dies with a sync activity body still
# in flight in the fork pool. Core's at_task_mgr.shutdown() waits for that body,
# and its graceful-period cancel would only ever arrive on an activity poll the
# dead loop no longer issues, so the drain plus the dead loop's in-flight await
# are what let finalize complete. The body's completion must still reach core:
# either the real result, or the drain's "Worker shutting down" replacement.
my $in_flight_child = sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
    );

    my $client;
    my $cleanup = sub {
        local $@;
        eval { $client->connection->close if defined $client; 1 };
        eval { $server->shutdown; 1 };
    };

    my $verified = 0;
    my $ok = eval {
        $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
            Temporalio::Client->connect(
                $server->target,
                namespace => 'default',
                runtime   => $runtime,
            );
        });

        my $injected = 'F3 injected activity poll failure';
        my $tasks    = 0;
        my $armed    = 0;
        my $sent     = 0;
        {
            no warnings 'redefine';
            my $orig_poll     = \&Temporalio::Worker::_poll_activity_task;
            my $orig_complete = \&Temporalio::Worker::_complete_activity_task;
            *Temporalio::Worker::_complete_activity_task = sub ($self, $bytes) {
                $sent++;
                return $orig_complete->($self, $bytes);
            };
            # One-shot, armed once a task has been handed to the dispatcher:
            # the poll that follows it is the one whose death strands the
            # running body.
            *Temporalio::Worker::_poll_activity_task = sub ($self) {
                if (!$armed && $tasks > 0) {
                    $armed = 1;
                    return Future->fail("$injected\n");
                }
                return $orig_poll->($self)->on_done(sub {
                    $tasks++ if defined $_[0];
                    return;
                });
            };
        }

        my $suffix     = "$$-" . int(rand(1_000_000));
        my $task_queue = "perl-sdk-f3-inflight-$suffix";
        my $worker     = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => ['WfDef::ActivityCaller'],
            # A SYNC activity body: it runs in the IO::Async::Function fork
            # pool, so the sleep is a genuinely in-flight dispatch the loop
            # cannot take back once its next poll dies.
            activities => [
                Temporalio::Activity::FunctionDefinition->new(
                    name => 'SayHello',
                    code => sub ($name) { sleep 3; return "Hello, $name!" },
                ),
            ],
        );
        my $run_f = $worker->run;

        bounded($loop,
            $client->start_workflow('ActivityCaller', ['Ada'],
                id         => "perl-sdk-f3-inflight-wf-$suffix",
                task_queue => $task_queue),
            30, 'start_workflow');

        assert_unwound($loop, $run_f, $injected, 'in-flight activity');
        die "in-flight activity: the injection never armed\n" unless $armed;
        die "in-flight activity: no activity completion ever reached core,"
          . " so the stranded body was neither delivered nor replaced\n"
            unless $sent > 0;

        $verified = 1;
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

my %idle = SubprocessGuard::run_guarded($idle_queue_child, timeout => 120);
T2->ok($idle{ok},
    'a fatal poll-loop death unwinds run() organically: the healthy sibling'
  . ' is stopped via initiate_shutdown and finalize does not deadlock (I3)')
    or T2->diag($idle{reason});

my %evict = SubprocessGuard::run_guarded($pending_evict_child, timeout => 150);
T2->ok($evict{ok},
    'a workflow loop that dies while core still owes an eviction is drained,'
  . ' so the eviction is polled and replied to and finalize completes (F3)')
    or T2->diag($evict{reason});

my %in_flight = SubprocessGuard::run_guarded($in_flight_child, timeout => 150);
T2->ok($in_flight{ok},
    'an activity loop that dies with a body in flight still gets that body\'s'
  . ' completion to core, and finalize completes (F3)')
    or T2->diag($in_flight{reason});

T2->done_testing;
