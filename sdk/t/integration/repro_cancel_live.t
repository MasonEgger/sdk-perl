# ABOUTME: B3 repro (#5): a workflow parked on a NEVER-TRUE wait_condition, when
# ABOUTME: client-cancelled, must end Cancelled via CancelWorkflowExecution
# ABOUTME: WITHOUT a durable-timer workaround. SUBPROCESS-GUARDED (plan directive
# ABOUTME: 4): the worker+cancel scenario runs in a forked child under a hard
# ABOUTME: ~30s timeout; before the fix the raw "was cancelled" string fails the
# ABOUTME: workflow task forever and $handle->result never resolves (RED), so the
# ABOUTME: child times out / dies rather than hanging the parent prove run.
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
require Temporalio::Exception::WorkflowFailure;
require Temporalio::Exception::Cancelled;
require WfDef::NeverCondition;
require SubprocessGuard;

# The scenario, run entirely in the forked child. Returns 1 only when the
# never-true-wait_condition workflow ends cleanly Cancelled; any other outcome
# (raw-cancel error, wrong result, transport failure) returns false / dies, and
# a hung workflow task trips the parent's hard timeout.
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

        my $task_queue = 'perl-sdk-b3-live-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::NeverCondition)],
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        my $handle = $tw->start_workflow_with_retry($client,
            'NeverCondition', [],
            id         => "perl-sdk-b3-live-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );

        # Let the workflow start and park on the never-true wait_condition.
        $loop->await($loop->delay_future(after => 1.5));

        # Client cancel -> CancelWorkflow job. The runner must raise a throwable
        # Cancelled into the parked wait_condition, NOT native-cancel it.
        $tw->await_result($handle->cancel(reason => 'b3 never-true condition'), 30);

        # The workflow must end Cancelled: $handle->result raises WorkflowFailure
        # whose cause is Cancelled. Anything else (or a hang) is a failure.
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
            print STDERR "b3 live: expected WorkflowFailure/Cancelled, got err="
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
    'never-true wait_condition + client cancel -> Cancelled within 30s, no timer workaround (#5)')
    or T2->diag($r{reason});

T2->done_testing;
