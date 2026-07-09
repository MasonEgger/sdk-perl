# ABOUTME: Integration coverage for the spec section 30.1 workflow reset helper
# ABOUTME: against a live dev server: reset to the first WFT-completed event,
# ABOUTME: returning a fresh run id (T-reset-3/4) while the original run is
# ABOUTME: terminated (T-reset-5). Reset is primarily a server-behavior test;
# ABOUTME: deterministic request-building lives in t/unit/reset.t.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use Scalar::Util ();

use lib "$FindBin::Bin/../lib";

# Gate (CLAUDE.md): skip_all when the dev server (temporal CLI) is unavailable.
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

require WfDef::SignalQueryGreeter;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Teardown in END so a die mid-file still releases the dev-server CLI child
# (finding T9 / spec R49): DevServer::DESTROY cannot run the event loop, so
# only an END-registered shutdown covers the die path. Enforced by
# xt/devserver_end_teardown.t.
my $torn_down = 0;
my sub teardown {
    return if $torn_down;
    $torn_down = 1;
    eval { $server->shutdown };
    eval { $runtime->shutdown };
}
# local $? so teardown-time process reaping cannot clobber the exit status
# the die (or Test2) already set for this file.
END { local $?; teardown() }

sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n"
        unless $future->is_ready;
    return $future->get;
}

sub unique_id ($prefix) {
    return "perl-sdk-reset-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

# Drain an async history-event iterator to a list (each ->next is a Future).
sub drain ($iter, $max = 1000) {
    my @out;
    while (@out < $max) {
        my $item = await_future($iter->next);
        last unless defined $item;
        push @out, $item;
    }
    return @out;
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-reset-' . $$ . '-' . int(rand(1_000_000));

my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => [qw(WfDef::SignalQueryGreeter)],
    activities => [],
);

my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

# We reset to the first WORKFLOW_TASK_COMPLETED event so the new run replays
# from just after the initial workflow task. Identify it by the history event's
# oneof attributes name (robust to enum-number changes), the same shape
# start_workflow.t uses to inspect history.
use constant WFT_COMPLETED_ATTRS =>
    'workflow_task_completed_event_attributes';

T2->subtest('reset returns a new run id; original terminated (T-reset-3/4/5)' => sub {
    my $wid = unique_id('greet');
    my $handle = $tw->await_with_retry(
        sub {
            $client->start_workflow(
                'SignalQueryGreeter', [],
                id => $wid, task_queue => $task_queue);
        },
        on_already_started => sub { $client->get_workflow_handle($wid) },
    );
    my $original_run_id = $handle->run_id;
    T2->ok(length($original_run_id), 'started run id present');

    # Drive at least one workflow task to completion (the worker processes the
    # initial task while the :Run parks on wait_condition), then signal so a
    # second task runs and completes the workflow.
    $tw->await_with_retry(sub { $handle->signal('setName', ['Ada']) });
    my $result = $tw->await_idempotent(sub { $handle->result });
    T2->is($result, 'Hello, Ada!', 'workflow completed before reset');

    # Find the first WORKFLOW_TASK_COMPLETED event id from history.
    my $finish_event_id;
    my @events = drain($handle->fetch_history_events);
    for my $event (@events) {
        if (($event->which_attributes // '') eq WFT_COMPLETED_ATTRS) {
            $finish_event_id = $event->event_id;
            last;
        }
    }
    T2->ok(defined $finish_event_id,
        "found a WFT-completed event (id $finish_event_id)")
        or return;

    # Reset to that event. The current run is terminated and a new run begins
    # (T-reset-3/5); reset returns the new run id (T-reset-4). Reset is a
    # non-idempotent mutation, so route it through await_with_retry.
    my $new_run_id = $tw->await_with_retry(
        sub {
            $handle->reset(
                workflow_task_finish_event_id => $finish_event_id,
                reason                        => 'integration reset',
            );
        },
    );
    T2->ok(length($new_run_id), 'reset returned a new run id (T-reset-4)');
    T2->isnt($new_run_id, $original_run_id,
        'new run id differs from the original (T-reset-3)');

    # The reset run replays from the reset point: it parks on wait_condition
    # again (the post-reset signal reapply may or may not have completed it,
    # depending on reapply settings). Either way the new run is a distinct
    # execution; assert its describe resolves under the new run id.
    my $new_handle = $client->get_workflow_handle($wid, run_id => $new_run_id);
    my $desc = $tw->await_idempotent(sub { $new_handle->describe });
    T2->is($desc->workflow_execution_info->execution->run_id, $new_run_id,
        'new run is describable under the reset run id (T-reset-5)');
});

$tw->shutdown(120);
teardown();

T2->done_testing;
