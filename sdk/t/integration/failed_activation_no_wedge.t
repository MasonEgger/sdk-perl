# ABOUTME: R11 (finding R5) live fault-injection: a workflow whose :Query
# ABOUTME: handler returns a pending future makes the runner die mid-activation.
# ABOUTME: The WFT must FAIL (a failed completion reaches core, which fails the
# ABOUTME: legacy query) so the client's query errors fast instead of wedging.
# ABOUTME: SUBPROCESS-GUARDED: pre-fix the die was warned-and-swallowed and the
# ABOUTME: query hung until timeout, so the scenario runs under a hard deadline.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. The server binary is the temporal CLI; honor TEMPORAL_CLI first,
# then scan PATH. No download is ever attempted — offline CI must stay green.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Modules are LOADED (FFI symbols attached) in the parent, but NOTHING that
# starts sdk-core's Tokio threads runs here — the runtime is created only inside
# the forked child (SubprocessGuard requires this for a safe fork).
require Future;
require IO::Async::Loop;
require Scalar::Util;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require WfDef::PendingQuery;
require SubprocessGuard;

# The scenario, run entirely in the forked child. Returns 1 only when the
# 'pending' query FAILS promptly (the failed workflow-task completion reached
# core, which failed the legacy query request). Pre-fix the runner die was
# swallowed and the workflow task never completed, so the query hung: the
# bounded await below dies with its timeout message and the child returns
# false, rather than the hang wedging prove.
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

        my $task_queue = 'perl-sdk-r11-live-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::PendingQuery)],
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        my $handle = $tw->start_workflow_with_retry($client,
            'PendingQuery', [],
            id         => "perl-sdk-r11-live-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );

        # Let the workflow start and park on its long timer.
        $loop->await($loop->delay_future(after => 1.5));

        # The fault injection: the 'pending' query handler returns a pending
        # future, so the runner dies reading its result. With R11 the die
        # becomes a failed workflow-task completion; core fails the legacy
        # query and this call errors promptly. A wedge (no completion) makes
        # the bounded await die with "did not resolve within" instead.
        my $err = do {
            local $@;
            eval { $tw->await_result($handle->query('pending'), 25); 1 }
                ? undef : $@;
        };
        my $msg = Scalar::Util::blessed($err) && $err->can('message')
            ? ($err->message // '') : ($err // '');
        $verified = defined $err
            && $msg !~ /did not resolve within/
            && $msg =~ /is not yet (?:ready|complete)/;
        unless ($verified) {
            print STDERR 'r11 live: expected a prompt query failure carrying '
                . '"is not yet ready/complete", got err='
                . (Scalar::Util::blessed($err) ? ref($err) : ($err // 'undef'))
                . " msg=$msg\n";
        }
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
    'a die during activation processing fails the WFT — the query errors fast, no wedge (R11)')
    or T2->diag($r{reason});

T2->done_testing;
