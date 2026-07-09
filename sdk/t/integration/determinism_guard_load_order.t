# ABOUTME: R27 (finding R13) load-order repro: a workflow module COMPILED BEFORE worker
# ABOUTME: construction must still be trapped by the determinism guard. Pre-fix the guard installed
# ABOUTME: its CORE::GLOBAL overrides at Worker->new, which only affect call sites compiled AFTER
# ABOUTME: install, so a normally `use`d workflow calling `time` completed with a wall-clock value
# ABOUTME: instead of failing. SUBPROCESS-GUARDED: the live scenario runs in a forked child.
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

require IO::Async::Loop;
require Scalar::Util;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require SubprocessGuard;

# THE LOAD-ORDER POINT OF THE TEST (R27): the workflow module is required HERE,
# in the parent, long before any Worker exists. Its `time` call site therefore
# compiles before worker construction - exactly the ordering that left the body
# unguarded pre-fix. Post-fix the guard installs at Definition load (which the
# fixture's own `use Temporalio::Workflow` triggers before its body compiles),
# so the call site is trapped regardless of when the worker is built.
require WfDef::IllegalTime;

# Flatten an exception's message + cause chain (plus its stringification) so
# the child can match the non-determinism text wherever the failure converter
# put it.
my $flatten = sub ($err) {
    my $text = '';
    my $e    = $err;
    my $hops = 0;
    while (Scalar::Util::blessed($e) && $hops++ < 10) {
        $text .= ' ' . ($e->can('message') ? ($e->message // '') : '');
        $e = $e->can('cause') ? $e->cause : undef;
    }
    $text .= ' ' . ($err // '');
    return $text;
};

# The scenario, run entirely in the forked child: run the pre-compiled
# IllegalTime workflow on a live worker with nondeterminism_as_workflow_fail
# (so the trap is a terminal workflow failure, not an endlessly retried task
# failure) and verify the result await fails with the non-determinism message.
# Pre-fix the workflow COMPLETES with a wall-clock epoch and the child returns
# false (RED).
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

        my $task_queue = 'perl-sdk-r27-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client                          => $client,
            task_queue                      => $task_queue,
            workflows                       => [qw(WfDef::IllegalTime)],
            nondeterminism_as_workflow_fail => 1,
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        my $handle = $tw->start_workflow_with_retry($client,
            'IllegalTime', [],
            id         => "perl-sdk-r27-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );

        my $result;
        my $err = do {
            local $@;
            eval { $result = $tw->await_result($handle->result, 30); 1 }
                ? undef
                : $@;
        };

        if (defined $err && $flatten->($err) =~ /non-?determin/i) {
            $verified = 1;
        }
        else {
            print STDERR 'r27 load-order: expected a non-determinism workflow '
                . 'failure, got '
                . (defined $err
                    ? 'unrelated error: ' . $flatten->($err)
                    : 'a COMPLETED workflow (result='
                        . ($result // 'undef')
                        . ') - the pre-loaded body was not trapped')
                . "\n";
        }
        1;
    };
    my $scenario_err = $@;

    $cleanup->();
    $runtime->shutdown;

    die $scenario_err if !$ok && $scenario_err;
    return $verified;
};

my %r = SubprocessGuard::run_guarded($child, timeout => 60);
T2->ok($r{ok},
    'a workflow module compiled BEFORE worker construction is still trapped by the guard (R27/R13)')
    or T2->diag($r{reason});

T2->done_testing;
