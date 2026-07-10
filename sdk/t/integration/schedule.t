# ABOUTME: Phase 8 acceptance (spec section 25, P8.2): schedules end-to-end
# ABOUTME: against a live dev server — create/describe/list/update/delete
# ABOUTME: (T-sched-1), backfill (T-sched-2), cron round-trip (T-sched-3),
# ABOUTME: pause/unpause notes (T-sched-5), trigger (T-sched-6) and
# ABOUTME: list_matching_times (T-sched-7). Filters scheduled runs by workflow
# ABOUTME: TYPE, not exact id. skip_all without the dev server.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use File::Spec ();
use FindBin ();
use Scalar::Util ();

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

# Loaded after the gate so machines without the CLI never compile the FFI stack.
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Test::Worker;
require Temporalio::Client;
require Temporalio::Test::Client;
require Temporalio::Worker;
require Temporalio::Core::Proto;
require Temporalio::Schedule;

require WfDef::ScheduledNoop;

Temporalio::Core::Proto->load;

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
    return "perl-sdk-sched-$prefix-" . $$ . '-' . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-sched-' . $$ . '-' . int(rand(1_000_000));

# A worker so triggered/backfilled actions actually run (and we can poll
# num_actions). ScheduledNoop just echoes its argument — no activity needed.
my $worker = Temporalio::Worker->new(
    client     => $client,
    task_queue => $task_queue,
    workflows  => ['WfDef::ScheduledNoop'],
);
my $tw = Temporalio::Test::Worker->new(worker => $worker, loop => $loop);

# Run the loop briefly so background poll loops + the schedule machinery make
# progress while we wait on a condition.
sub pump ($seconds) {
    await_future($loop->delay_future(after => $seconds), $seconds + 5);
}

# describe() is an idempotent read. On this loaded box a transient
# DEADLINE_EXCEEDED can fire mid-describe; treat it as "no answer yet" inside
# the poll loop (keep polling) rather than aborting the subtest. A non-timeout
# RpcError still surfaces. Re-issues a fresh future each call.
sub describe_tolerant ($handle) {
    return $tw->await_idempotent(sub { $handle->describe });
}

# Poll a schedule handle's num_actions until it reaches $target (or time out).
sub await_num_actions ($handle, $target, $timeout = 60) {
    my $deadline = time + $timeout;
    while (time < $deadline) {
        my $desc = describe_tolerant($handle);
        return $desc if $desc->info->num_actions >= $target;
        pump(1);
    }
    return describe_tolerant($handle);
}

sub a_schedule (%o) {
    return Temporalio::Schedule::Schedule->new(
        action => Temporalio::Schedule::Action::StartWorkflow->new(
            workflow   => 'ScheduledNoop',
            args       => [ $o{arg} // 'arg1' ],
            id         => $o{wf_id} // unique_id('wf'),
            task_queue => $task_queue,
        ),
        spec  => $o{spec} // Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 60) ]),
        policy => Temporalio::Schedule::Policy->new(
            overlap => $o{overlap} // 'buffer_one'),
        state => $o{state} // Temporalio::Schedule::State->new(paused => 1),
    );
}

# ---------------------------------------------------------------------------
# T-sched-1: basic create/describe/list/update/delete; update mutates the
# action args (arg1 -> arg2).
# ---------------------------------------------------------------------------
T2->subtest('basic create/describe/list/update/delete (T-sched-1)' => sub {
    my $sid = unique_id('basic');
    my $wf_id = unique_id('basic-wf');
    my $handle = await_future($client->create_schedule(
        $sid, a_schedule(arg => 'arg1', wf_id => $wf_id,
            overlap => 'buffer_one')));
    T2->is($handle->id, $sid, 'create returned a handle with the id');

    my $desc = await_future($handle->describe);
    T2->is($desc->id, $sid, 'describe id matches');
    T2->is($desc->schedule->action->workflow, 'ScheduledNoop',
        'action workflow type round-tripped');
    T2->is($desc->schedule->policy->overlap, 'buffer_one',
        'overlap policy round-tripped');

    # list_schedules — find ours by id among the listed schedules.
    my $found = 0;
    my $it = $client->list_schedules;
    while (defined(my $entry = await_future($it->next))) {
        $found = 1, last if $entry->id eq $sid;
    }
    T2->ok($found, 'created schedule appears in list_schedules');

    # update: mutate the action args arg1 -> arg2 (single-shot).
    await_future($handle->update(sub ($input) {
        my $sched = $input->description->schedule;
        my $action = $sched->action;
        my $new_action = Temporalio::Schedule::Action::StartWorkflow->new(
            workflow   => $action->workflow,
            args       => ['arg2'],
            id         => $action->id,
            task_queue => $action->task_queue,
        );
        my $new_sched = Temporalio::Schedule::Schedule->new(
            action => $new_action,
            spec   => $sched->spec,
            policy => $sched->policy,
            state  => $sched->state,
        );
        return Temporalio::Schedule::Update->new(schedule => $new_sched);
    }));

    # The action holds workflow input as RAW Payloads for round-trip fidelity,
    # so decode the new args straight from the describe response proto.
    my $desc2 = await_future($handle->describe);
    my $input = $desc2->raw_description->schedule->action->start_workflow->input;
    my ($arg) =
        await_future($client->data_converter->from_payloads($input->payloads));
    T2->is($arg, 'arg2', 'update mutated the action arg (arg1 -> arg2)');

    await_future($handle->delete);
    my $deleted = do {
        local $@;
        eval { await_future($handle->describe); 1 } ? 0 : 1;
    };
    T2->ok($deleted, 'describe after delete fails (NotFound)');
});

# ---------------------------------------------------------------------------
# T-sched-5: pause/unpause notes (pure-client assert paused + exact notes).
# ---------------------------------------------------------------------------
T2->subtest('pause/unpause notes (T-sched-5)' => sub {
    my $sid = unique_id('pause');
    my $handle = await_future($client->create_schedule($sid, a_schedule()));

    await_future($handle->pause);
    my $d1 = await_future($handle->describe);
    T2->ok($d1->schedule->state->paused, 'schedule is paused');
    T2->is($d1->schedule->state->note, 'Paused via Perl SDK',
        'default pause note set');

    await_future($handle->unpause);
    my $d2 = await_future($handle->describe);
    T2->ok(!$d2->schedule->state->paused, 'schedule is unpaused');
    T2->is($d2->schedule->state->note, 'Unpaused via Perl SDK',
        'default unpause note set');

    await_future($handle->delete);
});

# ---------------------------------------------------------------------------
# T-sched-6: trigger twice (paused); poll until num_actions == 2.
# ---------------------------------------------------------------------------
T2->subtest('trigger twice -> num_actions == 2 (T-sched-6)' => sub {
    my $sid = unique_id('trigger');
    my $handle = await_future($client->create_schedule(
        $sid, a_schedule(overlap => 'allow_all')));

    # Fire one trigger, let the schedule pick it up, then fire the second so the
    # two actions are distinct scheduling decisions (allow_all overlap).
    await_future($handle->trigger);
    my $first = await_num_actions($handle, 1, 90);
    T2->ok($first->info->num_actions >= 1, 'first trigger produced an action')
        or T2->diag('after first trigger num_actions='
            . $first->info->num_actions);
    await_future($handle->trigger);

    my $desc = await_num_actions($handle, 2, 120);
    T2->ok($desc->info->num_actions >= 2,
        'two triggers produced at least two actions')
        or T2->diag('num_actions=' . $desc->info->num_actions);

    await_future($handle->delete);
});

# ---------------------------------------------------------------------------
# T-sched-2: backfill two windows (allow_all) on a paused schedule; poll until
# the actions land.
# ---------------------------------------------------------------------------
T2->subtest('backfill two windows (T-sched-2)' => sub {
    my $sid = unique_id('backfill');
    # Per-minute spec so the backfill windows contain several fire points.
    my $handle = await_future($client->create_schedule($sid, a_schedule(
        overlap => 'allow_all',
        spec    => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 60) ]),
    )));

    my $now = time;
    my $bf1 = Temporalio::Schedule::Backfill->new(
        start_at => $now - 600, end_at => $now - 480, overlap => 'allow_all');
    my $bf2 = Temporalio::Schedule::Backfill->new(
        start_at => $now - 480, end_at => $now - 360, overlap => 'allow_all');
    await_future($handle->backfill($bf1, $bf2));

    my $desc = await_num_actions($handle, 1, 40);
    T2->ok($desc->info->num_actions >= 1,
        'backfill produced at least one action')
        or T2->diag('num_actions=' . $desc->info->num_actions);

    await_future($handle->delete);
});

# ---------------------------------------------------------------------------
# T-sched-3: cron round-trip — a Perl-authored ScheduleSpec.cron_expressions
# survives create -> describe (the server compiles it into a structured
# calendar, so cron_expressions comes back empty but a calendar is present).
# ---------------------------------------------------------------------------
T2->subtest('cron expression round-trip (T-sched-3)' => sub {
    my $sid = unique_id('cron');
    my $handle = await_future($client->create_schedule($sid, a_schedule(
        spec => Temporalio::Schedule::Spec->new(
            cron_expressions => ['*/5 * * * *']),
        state => Temporalio::Schedule::State->new(paused => 1),
    )));

    my $desc = await_future($handle->describe);
    my $spec = $desc->schedule->spec;
    # Server compiles cron into a structured calendar; cron_expressions is empty
    # on read but a calendar (or interval) describes the same cadence.
    T2->ok(scalar(@{ $spec->calendars }) || scalar(@{ $spec->intervals }),
        'cron compiled into a structured calendar/interval on describe')
        or T2->diag('no structured spec returned for cron');

    await_future($handle->delete);
});

# ---------------------------------------------------------------------------
# T-sched-7: list_matching_times — projected fire times for an interval spec.
# No public handle method exists (neither reference SDK exposes one and the
# spec section 25.1 surface omits it), so issue ListScheduleMatchingTimes
# directly through the client RPC path and assert the projection is non-empty.
# ---------------------------------------------------------------------------
T2->subtest('list_matching_times projects fire times (T-sched-7)' => sub {
    my $sid = unique_id('matching');
    my $handle = await_future($client->create_schedule($sid, a_schedule(
        spec => Temporalio::Schedule::Spec->new(
            intervals => [ Temporalio::Schedule::Interval->new(every => 60) ]),
    )));

    my $Ts = Temporalio::Core::Proto::resolve('google.protobuf.Timestamp');
    my $now = time;
    my $req = Temporalio::Core::Proto::resolve(
        'temporal.api.workflowservice.v1.ListScheduleMatchingTimesRequest')
        ->new({
            namespace   => 'default',
            schedule_id => $sid,
            start_time  => $Ts->new({ seconds => $now }),
            end_time    => $Ts->new({ seconds => $now + 600 }),
        });
    my $resp = await_future(
        $client->_rpc_call('ListScheduleMatchingTimes', $req));
    my $times = $resp->start_time;
    T2->ok(scalar(@$times) > 0,
        'projected fire times within a 10-minute window are non-empty')
        or T2->diag('matching times count: ' . scalar(@$times));

    await_future($handle->delete);
});

# Clean shutdown: drain the worker, close the client, stop the server.
$tw->shutdown(120);
T2->ok($worker->is_shutdown, 'worker shut down cleanly');

$client->connection->close if defined $client;
teardown();

T2->done_testing;
