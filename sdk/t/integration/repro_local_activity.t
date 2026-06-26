# ABOUTME: B5 repro (#9): a live workflow that runs execute_local_activity must
# ABOUTME: return the activity result and tear down cleanly. Today the worker
# ABOUTME: hardcodes enable_local_activities => 0, so the first ScheduleLocalActivity
# ABOUTME: command core receives crashes the worker (SEGV / exit 139). The whole
# ABOUTME: lifecycle runs in a forked child under a hard timeout; the child exits 0
# ABOUTME: only on a verified-clean local-activity result, so the SEGV reads as a
# ABOUTME: non-zero exit (RED) instead of wedging the suite.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. Honor TEMPORAL_CLI first, then scan PATH; never download.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

# Modules LOADED (FFI symbols attached) in the parent; NOTHING that starts
# sdk-core's Tokio threads runs here. The runtime is created only in the child.
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require Temporalio::Activity::FunctionDefinition;
require Temporalio::Exception::Application;
require WfDef::LocalActivityCaller;
require WfDef::LocalActivityRetry;
require SubprocessGuard;

# Run one local-activity workflow scenario end to end in a forked child. Returns
# 1 only when the workflow result matches AND the full teardown (worker, client,
# dev server, runtime) completes without crashing core. A SEGV in the local-
# activity path kills the child with signal 11, which SubprocessGuard reports as
# a non-zero exit.
sub la_scenario ($workflow_class, $wf_type, $activities, $args, $expected) {
    return sub {
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

        my $ok = eval {
            $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
                Temporalio::Client->connect(
                    $server->target,
                    namespace => 'default',
                    runtime   => $runtime,
                );
            });

            my $task_queue = "perl-sdk-b5-la-$$-" . int(rand(1_000_000));
            my $worker = Temporalio::Worker->new(
                client     => $client,
                task_queue => $task_queue,
                workflows  => [$workflow_class],
                activities => $activities,
            );
            $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

            my $handle = $tw->start_workflow_with_retry($client,
                $wf_type, $args,
                id         => "perl-sdk-b5-la-$$-" . int(rand(1_000_000)),
                task_queue => $task_queue,
            );

            my $result = $tw->await_result($handle->result, 60);
            unless (defined $result && $result eq $expected) {
                print STDERR "b5 la: unexpected result for $wf_type: "
                    . (defined $result ? $result : 'undef')
                    . " (wanted $expected)\n";
            }

            $tw->shutdown(30);
            $client->connection->close if defined $client;
            $server->shutdown;

            $verified = (defined $result && $result eq $expected) ? 1 : 0;
            1;
        };
        my $scenario_err = $@;

        eval { $server->shutdown unless $server->is_shutdown; 1 };
        $runtime->shutdown;

        die $scenario_err if !$ok && $scenario_err;
        return $verified;
    };
}

# Case 1: a plain local activity returns its result with no SEGV.
my $plain_activities = [
    Temporalio::Activity::FunctionDefinition->new(
        name => 'SayHello',
        code => sub ($name) { return "hello, $name" },
    ),
];
my %r1 = SubprocessGuard::run_guarded(
    la_scenario('WfDef::LocalActivityCaller', 'LocalActivityCaller',
        $plain_activities, ['Ada'], 'got: hello, Ada'),
    timeout => 60,
);
T2->ok($r1{ok},
    'plain execute_local_activity returns its result and tears down cleanly (no SEGV) (#9)')
    or T2->diag($r1{reason});

# Case 2: a local activity with start_to_close_timeout + retry_policy drives the
# backoff/re-schedule loop (fails attempt 1, succeeds attempt 2).
my $attempts = 0;
my $retry_activities = [
    Temporalio::Activity::FunctionDefinition->new(
        name => 'FlakySayHello',
        code => sub ($name) {
            $attempts++;
            if ($attempts < 2) {
                Temporalio::Exception::Application->throw(
                    message => "flaky attempt $attempts",
                    type    => 'FlakyError',
                );
            }
            return "hello again, $name";
        },
    ),
];
my %r2 = SubprocessGuard::run_guarded(
    la_scenario('WfDef::LocalActivityRetry', 'LocalActivityRetry',
        $retry_activities, ['Bob'], 'got: hello again, Bob'),
    timeout => 90,
);
T2->ok($r2{ok},
    'local activity with start_to_close_timeout + retry_policy completes via backoff (no SEGV) (#9)')
    or T2->diag($r2{reason});

T2->done_testing;
