# ABOUTME: B4 repro / regression guard (#2): workflow A signals workflow B twice
# ABOUTME: through get_external_workflow_handle; both signals must be delivered.
# ABOUTME: SUBPROCESS-GUARDED so a stalled second hand-off trips a hard timeout
# ABOUTME: rather than wedging prove. The B4 investigation found #2 already
# ABOUTME: healthy on current v1; this file keeps it green as a regression guard.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): integration tests skip_all when the dev server is
# unavailable. Honor TEMPORAL_CLI first, then scan PATH. No download attempted.
my $cli = $ENV{TEMPORAL_CLI};
if (!(defined $cli && -x $cli)) {
    ($cli) = grep { -x $_ }
        map { File::Spec->catfile($_, 'temporal') } File::Spec->path;
}
T2->skip_all('temporal CLI not found (install temporal or set TEMPORAL_CLI)')
    unless defined $cli && -x $cli;

require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Test::Worker;
require WfDef::TwiceSignaller;
require WfDef::TwiceCounter;
require SubprocessGuard;

# Child scenario: start the counter target, then a signaller that delivers two
# 'tick' signals via the external handle. Returns 1 only when the target's
# wait_condition (count >= 2) resolves and its result is exactly 2.
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

        my $task_queue = 'perl-sdk-b4-ext-' . $$ . '-' . int(rand(1_000_000));
        my $worker = Temporalio::Worker->new(
            client     => $client,
            task_queue => $task_queue,
            workflows  => [qw(WfDef::TwiceSignaller WfDef::TwiceCounter)],
        );
        $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

        my $target_id = "perl-sdk-b4-ext-target-$$-" . int(rand(1_000_000));
        my $target = $tw->start_workflow_with_retry($client,
            'TwiceCounter', [],
            id         => $target_id,
            task_queue => $task_queue,
        );

        my $signaller = $tw->start_workflow_with_retry($client,
            'TwiceSignaller', [$target_id],
            id         => "perl-sdk-b4-ext-driver-$$-" . int(rand(1_000_000)),
            task_queue => $task_queue,
        );

        my $sig_result = $tw->await_result($signaller->result, 60);
        my $count      = $tw->await_result($target->result, 60);

        $verified = (defined $sig_result && $sig_result eq 'done'
                     && defined $count && $count == 2) ? 1 : 0;
        unless ($verified) {
            print STDERR "b4 ext: signaller=" . ($sig_result // 'undef')
                . " count=" . ($count // 'undef') . "\n";
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
    'workflow A signals workflow B twice via external handle; both delivered (#2)')
    or T2->diag($r{reason});

T2->done_testing;
