# ABOUTME: B10 repro (#4): a wait_condition WITH A TIMEOUT whose backing durable timer is
# ABOUTME: cancelled and re-armed against a MOVED deadline (the updatable-timer pattern). Arm a
# ABOUTME: long timer behind the wait_condition timeout, an :Update pulls the deadline NEARER, the
# ABOUTME: loop must cancel the stale long timer and re-arm a SHORT timer so the workflow wakes at
# ABOUTME: the new deadline. SUBPROCESS-GUARDED (plan directive 4): the worker + start + update
# ABOUTME: scenario runs in a forked child under a hard timeout; before the fix the re-arm wedges
# ABOUTME: and the workflow sleeps the FULL long timer, tripping the timeout (RED).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): skip_all when the temporal CLI / dev server is unavailable.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

require Future;
require IO::Async::Loop;
require Scalar::Util;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require WfDef::DeadlineMover;
require SubprocessGuard;

# The scenario, run entirely in the forked child. Starts the DeadlineMover workflow with a FAR
# wake epoch (a long backing timer), moves the deadline NEAR via the `move` :Update, then awaits
# the result. Returns 1 only when the workflow wakes promptly at the moved (near) deadline within
# the budget; the pre-fix re-arm wedge leaves it parked on the stale long timer and the parent
# hard timeout trips instead.
my $child = sub {
    my $loop    = IO::Async::Loop->new;
    my $runtime = Temporalio::Runtime->new(loop => $loop);

    my $server = Temporalio::Test::DevServer->start(
        runtime       => $runtime,
        existing_path => $cli,
        log_level     => 'warn',
    );

    my $verified = 0;
    my $tw;
    my $client;
    my $cleanup = sub {
        local $@;
        eval { $tw->shutdown(30) if defined $tw; 1 };
        eval { $client->connection->close if defined $client; 1 };
        eval { $server->shutdown; 1 };
    };

    my $ok = eval {
        $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
            Temporalio::Client->connect(
                $server->target,
                namespace => 'default',
                runtime   => $runtime,
            );
        });

        my $task_queue = 'perl-sdk-b10-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::DeadlineMover)],
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        # FAR wake: a long backing timer the update must cancel. NEAR wake: a few seconds out.
        my $now       = time;
        my $far_wake  = $now + 100;   # the long timer
        my $near_wake = $now + 3;     # pulled in by the update

        my $handle = $tw->start_workflow_with_retry($client,
            'DeadlineMover', [$far_wake],
            id         => "perl-sdk-b10-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );

        # Move the deadline NEARER. The update cancels the long timer and re-arms a short timer.
        my $ack = $tw->await_result(
            $handle->execute_update('move', [$near_wake]), 30);

        # The workflow must wake at the NEW (near) deadline, well before the far one. If the
        # re-arm wedges, it sleeps the full 100s and this await trips the parent timeout.
        my $woke = $tw->await_result($handle->result, 30);
        $verified = ($woke >= $near_wake && $woke < $far_wake) ? 1 : 0;
        unless ($verified) {
            print STDERR "b10 re-arm: woke=$woke near=$near_wake far=$far_wake (ack=$ack)\n";
        }
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

my %r = SubprocessGuard::run_guarded($child, timeout => 45);
T2->ok($r{ok},
    'wait_condition-timeout re-arm on a moved deadline wakes at the new deadline, no wedge (#4)')
    or T2->diag($r{reason});

T2->done_testing;
