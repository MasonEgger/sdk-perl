# ABOUTME: B3 repro (#8): a client cancel landing while an :Update handler is
# ABOUTME: mid-flight (parked on a never-true wait_condition) must surface a
# ABOUTME: clean WorkflowFailure/Cancelled, not hang the workflow task (~183s
# ABOUTME: today). SUBPROCESS-GUARDED (plan directive 4): the worker + start-
# ABOUTME: update + cancel scenario runs in a forked child under a hard ~30s
# ABOUTME: timeout; before the fix the mid-update cancel hangs and the child
# ABOUTME: trips the timeout (RED) rather than wedging the parent prove run.
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

# Loaded (FFI attached) in the parent; the runtime is created only in the child.
require Future;
require IO::Async::Loop;
require Scalar::Util;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Exception::WorkflowFailure;
require Temporalio::Exception::Cancelled;
require WfDef::UpdateParker;
require SubprocessGuard;

# The scenario, run entirely in the forked child. Starts the workflow, starts an
# update that parks mid-flight (wait_for_stage => 'accepted' returns once the
# handler is genuinely in-flight), then client-cancels the run. Returns 1 only
# when the workflow ends cleanly Cancelled within the budget; the pre-fix
# mid-update hang trips the parent's hard timeout instead.
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

        my $task_queue = 'perl-sdk-b3-upd-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::UpdateParker)],
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        my $handle = $tw->start_workflow_with_retry($client,
            'UpdateParker', [],
            id         => "perl-sdk-b3-upd-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );

        # Start the update and wait only for ACCEPTED: the handler runs to its
        # first await and parks on the never-true wait_condition, so by the time
        # this returns the update is genuinely mid-flight.
        $tw->await_result(
            $handle->start_update('park', [], wait_for_stage => 'accepted'), 30);

        # Client cancel lands while the handler is parked mid-update. The runner
        # must raise a throwable Cancelled into BOTH the :Run body and the
        # in-flight handler's await rather than leaking a raw cancelled Future.
        $tw->await_result($handle->cancel(reason => 'b3 mid-update cancel'), 30);

        # The workflow must end Cancelled cleanly (no ~183s hang).
        my $err = do {
            local $@;
            eval { $tw->await_result($handle->result, 20); 1 } ? undef : $@;
        };
        my $cause = (Scalar::Util::blessed($err) && $err->can('cause'))
            ? $err->cause : undef;
        $verified =
            Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::WorkflowFailure')
            && Scalar::Util::blessed($cause)
            && $cause->isa('Temporalio::Exception::Cancelled');
        unless ($verified) {
            print STDERR "b3 mid-update: expected WorkflowFailure/Cancelled, got err="
                . (Scalar::Util::blessed($err) ? ref($err) : ($err // 'undef'))
                . " cause=" . (Scalar::Util::blessed($cause) ? ref($cause) : 'undef')
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

my %r = SubprocessGuard::run_guarded($child, timeout => 30);
T2->ok($r{ok},
    'client cancel mid-:Update -> clean WorkflowFailure/Cancelled within 30s (#8)')
    or T2->diag($r{reason});

T2->done_testing;
