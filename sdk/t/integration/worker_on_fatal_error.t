# ABOUTME: R94 (parity audit worker finding 3) acceptance: Worker->new gains an
# ABOUTME: on_fatal_error coderef invoked with the fatal poll-loop error before
# ABOUTME: run()'s fatal-path shutdown; a throwing hook is warned and ignored so
# ABOUTME: the original failure still propagates from run(). Python
# ABOUTME: _worker.py:134 (kwarg), :289-291 (contract), :822-825 (invocation).
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Code trace (spec R94 / parity audit worker finding 3): pre-fix, Worker.pm has
# no on_fatal_error kwarg — run()'s single fatal-path unwind (the R62 rework:
# $error saved from the settled poll loops, finalize failures attached as
# secondaries, one `die $error` at the end) gives the caller no look at the
# fatal error before the shutdown sequence commences. Python accepts
# `on_fatal_error` (_worker.py:134), documents that it cannot stop the shutdown
# and that any exception it raises is logged and ignored (:289-291), and awaits
# it right after the fatal worker-task exception is captured, before bridge
# initiate_shutdown, under a bare-except warning guard (:822-825). The guarded
# scenarios pin the Perl equivalent live:
#   * a worker whose poll loops die fatally invokes the on_fatal_error coderef
#     with the error while run() is still pending (before run() returns);
#   * a THROWING hook is warned and ignored: the original fatal failure still
#     propagates from run() and the hook's own error does not replace or
#     attach to it;
#   * edge (R44 strictness): a non-coderef on_fatal_error raises the typed
#     Argument error at construction.
# Inducement: the poll methods are wrapped record-then-delegate (the R92/R93
# pattern); each delegates to the real core poll and transforms the ShutDown
# sentinel into a failure. Initiating shutdown then turns both drained
# sentinels into poll-loop deaths, so core is fully drained and the fatal
# unwind (initiate -> finalize -> free) completes instead of deadlocking in
# finalize on undrained polls (the P2.2 lesson).

# Gate (CLAUDE.md): skip when the temporal CLI is unavailable; offline CI
# stays green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Modules are LOADED (FFI symbols attached) in the parent, but NOTHING that
# starts sdk-core's Tokio threads runs here — the runtime is created only
# inside the forked child (SubprocessGuard requires this for a safe fork).
require Future;
require IO::Async::Loop;
require Scalar::Util;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Exception::Argument;
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

    my $verified = 0;
    my $client;
    my $cleanup = sub {
        local $@;
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

        # Poll wrappers (the R92/R93 record-then-delegate pattern): delegate
        # to the real core poll; a real task passes through untouched and the
        # ShutDown sentinel (undef) becomes a poll-loop death. $polls_started
        # resolves once BOTH loops have issued a poll, so the test only
        # initiates shutdown against a live, draining worker.
        my $injected = "R94 injected poll-loop failure\n";
        my ($polls_seen, $polls_started);
        my $arm_polls = sub {
            $polls_seen    = 0;
            $polls_started = $loop->new_future;
        };
        my $wrap = sub ($orig) {
            return sub {
                my @args = @_;
                $polls_seen++;
                $polls_started->done(1)
                    if $polls_seen >= 2 && !$polls_started->is_ready;
                return $orig->(@args)->then(sub {
                    my @r = @_;
                    return defined $r[0]
                        ? Future->done(@r)
                        : Future->fail($injected);
                });
            };
        };
        {
            no warnings 'redefine';
            *Temporalio::Worker::_poll_activity_task =
                $wrap->(\&Temporalio::Worker::_poll_activity_task);
            *Temporalio::Worker::_poll_workflow_activation =
                $wrap->(\&Temporalio::Worker::_poll_workflow_activation);
        }

        # Drive one worker to its fatal poll-loop death and hand back the
        # settled run future. Shared by both scenarios. $current_run_f lets a
        # hook body observe the in-flight run future's state (the direct
        # "before run() returns" proof).
        my $current_run_f;
        my $run_to_fatal = sub ($worker) {
            $arm_polls->();
            my $run_f = $worker->run;
            $current_run_f = $run_f;
            $loop->await(Future->wait_any(
                $polls_started->without_cancel,
                $loop->timeout_future(after => 30),
            ));
            die "poll loops never started\n" unless $polls_started->is_ready;
            $worker->shutdown;    # sentinel -> injected poll-loop death
            $loop->await(Future->wait_any(
                $run_f->without_cancel,
                $loop->timeout_future(after => 60),
            ));
            die "run() did not settle within 60s after the fatal\n"
                unless $run_f->is_ready;
            return $run_f;
        };

        # --- scenario 1: hook fires with the error before run() returns ----
        my @events;
        my $hook_error;
        my $run_pending_at_hook;
        my $worker_a;
        $worker_a = Temporalio::Worker->new(
            client         => $client,
            task_queue     => "perl-sdk-r94-a-$$-" . int(rand(1_000_000)),
            workflows      => ['WfDef::QueryGreeter'],
            on_fatal_error => sub ($error) {
                push @events, 'hook';
                $hook_error = $error;
                # The direct pre-return proof: run()'s future must still be
                # pending while the hook runs.
                $run_pending_at_hook =
                    defined $current_run_f && !$current_run_f->is_ready;
                return;
            },
        );
        my $run_a = $run_to_fatal->($worker_a);
        push @events, 'run-settled';
        die "run() did not fail\n" unless $run_a->is_failed;
        my ($err_a) = $run_a->failure;
        die "run() failed with '$err_a', not the injected poll failure\n"
            unless "$err_a" =~ /R94 injected poll-loop failure/;
        die "on_fatal_error was not invoked before run() returned\n"
            unless @events >= 2
                && $events[0] eq 'hook'
                && $events[-1] eq 'run-settled';
        die "hook ran after run()'s future settled\n"
            unless $run_pending_at_hook;
        die "on_fatal_error received '" . ($hook_error // 'undef')
          . "', not the fatal error\n"
            unless defined $hook_error
                && "$hook_error" =~ /R94 injected poll-loop failure/;

        # --- scenario 2: a throwing hook is warned and ignored --------------
        my $hook2_called = 0;
        my $worker_b     = Temporalio::Worker->new(
            client         => $client,
            task_queue     => "perl-sdk-r94-b-$$-" . int(rand(1_000_000)),
            workflows      => ['WfDef::QueryGreeter'],
            on_fatal_error => sub ($error) {
                $hook2_called = 1;
                die "R94 hook explosion\n";
            },
        );
        my @warnings;
        my $run_b = do {
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            $run_to_fatal->($worker_b);
        };
        die "throwing-hook run() did not fail\n" unless $run_b->is_failed;
        my ($err_b) = $run_b->failure;
        die "throwing hook was not invoked\n" unless $hook2_called;
        die "original failure was masked; run() failed with '$err_b'\n"
            unless "$err_b" =~ /R94 injected poll-loop failure/;
        die "hook error leaked into run()'s failure: '$err_b'\n"
            if "$err_b" =~ /hook explosion/;
        die "throwing hook was not logged (no on_fatal_error warning)\n"
            unless grep { /on_fatal_error/ && /hook explosion/ } @warnings;

        # --- edge (R44 strictness): non-coderef raises typed Argument -------
        my $bad_err = do {
            local $@;
            eval {
                Temporalio::Worker->new(
                    client         => $client,
                    task_queue     => 'perl-sdk-r94-bad',
                    workflows      => ['WfDef::QueryGreeter'],
                    on_fatal_error => 'not a coderef',
                );
                1;
            } ? undef : $@;
        };
        die "non-coderef on_fatal_error did not raise the typed Argument"
          . " error\n"
            unless Scalar::Util::blessed($bad_err)
                && $bad_err->isa('Temporalio::Exception::Argument');

        $verified = 1;
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

my %r = SubprocessGuard::run_guarded($child, timeout => 150);
T2->ok($r{ok},
    'on_fatal_error fires with the fatal poll-loop error before run()'
  . ' returns; a throwing hook is warned and ignored without masking the'
  . ' original failure (R94)')
    or T2->diag($r{reason});

T2->done_testing;
