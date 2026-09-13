# ABOUTME: I3 (parity audit worker finding 3, GitHub issue #3) acceptance: a
# ABOUTME: fatal poll-loop death must unwind Worker::run organically (no test
# ABOUTME: code calling shutdown itself): run() returns the fatal error, the
# ABOUTME: healthy sibling loop is stopped via initiate_shutdown, and finalize
# ABOUTME: does not deadlock on an undrained poll. Subprocess-guarded because
# ABOUTME: the pre-fix failure mode is a HANG, not a wrong answer.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Code trace (spec I3): pre-fix, Worker.pm run() (:571) gathers the per-kind
# poll loops with `await Future->wait_all(@loops)` (:615), which settles only
# once EVERY loop is ready. Here the activity loop dies fatally on its very
# first poll while the workflow loop keeps long-polling a live, otherwise-idle
# task queue with no shutdown ever requested: an organic, never-resolving
# healthy sibling, exactly the real-world trigger. (The R94 on_fatal_error
# test cannot exercise this: worker_initiate_shutdown is worker-wide, so
# calling $worker->shutdown up front (R94's technique) flips the sentinel
# for EVERY poll kind at once, which is why R94 passes today even though the
# underlying wait_all gather has never had to race anything.) The activity
# poll's REAL worker_poll_activity_task FFI call is still issued (fired and
# left to settle on its own later, once THIS fix's own _initiate_shutdown_once
# call reaches it) so core's own per-kind poller bookkeeping is never starved
# of a call it expects: skipping the real call entirely deadlocks
# _finalize_and_free on an activity poller that never started, a DIFFERENT
# hang than the one under test here. Python parity: ../sdk-python
# worker/_worker.py:812 (FIRST_EXCEPTION wait) and :846-848
# (drain_poll_queue): replace wait_all with a first-failure race, then
# initiate shutdown and drain the survivors before finalize.
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
require WfDef::QueryGreeter;
require SubprocessGuard;

my $child = sub {
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
        # needs to collect that result.
        my $injected = "I3 injected poll-loop failure\n";
        {
            no warnings 'redefine';
            my $orig = \&Temporalio::Worker::_poll_activity_task;
            *Temporalio::Worker::_poll_activity_task = sub ($self) {
                $orig->($self);
                return Future->fail($injected);
            };
        }

        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => "perl-sdk-i3-$$-" . int(rand(1_000_000)),
            workflows  => ['WfDef::QueryGreeter'],
        );

        my $run_f = $worker->run;
        $loop->await(Future->wait_any(
            $run_f->without_cancel,
            $loop->timeout_future(after => 60),
        ));
        die "run() did not unwind within 60s of the fatal poll-loop death"
          . " (a fatal loop is still blocking on a healthy sibling,"
          . " I3 regression)\n"
            unless $run_f->is_ready;
        die "run() did not FAIL: the injected fatal error was lost\n"
            unless $run_f->is_failed;
        my ($err) = $run_f->failure;
        die "run() failed with '$err', not the injected poll-loop failure\n"
            unless "$err" =~ /I3 injected poll-loop failure/;

        $verified = 1;
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

my %r = SubprocessGuard::run_guarded($child, timeout => 90);
T2->ok($r{ok},
    'a fatal poll-loop death unwinds run() organically: the healthy sibling'
  . ' is stopped via initiate_shutdown and finalize does not deadlock (I3)')
    or T2->diag($r{reason});

T2->done_testing;
