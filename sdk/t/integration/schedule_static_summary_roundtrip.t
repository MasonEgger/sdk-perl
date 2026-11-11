# ABOUTME: Integration acceptance for spec I4 (GitHub issue #4): a schedule
# ABOUTME: action's static_summary must survive a live describe -> modify ->
# ABOUTME: update -> describe cycle, not just a bare create -> describe.
# ABOUTME: skip_all without a dev server.
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

# Loaded after the gate so machines without the CLI never compile the FFI stack.
require Future;
require IO::Async::Loop;
require Temporalio::Runtime;
require Temporalio::Test::DevServer;
require Temporalio::Test::Client;
require Temporalio::Client;
require Temporalio::Core::Proto;
require Temporalio::Schedule;

Temporalio::Core::Proto->load;

my $loop    = IO::Async::Loop->new;
my $runtime = Temporalio::Runtime->new(loop => $loop);

my $server = Temporalio::Test::DevServer->start(
    runtime       => $runtime,
    existing_path => $cli,
    log_level     => 'warn',
);

# Teardown in END (finding T9 / spec R49; see t/integration/schedule.t).
my $torn_down = 0;
my sub teardown {
    return if $torn_down;
    $torn_down = 1;
    eval { $server->shutdown };
    eval { $runtime->shutdown };
}
END { local $?; teardown() }

sub await_future ($future, $timeout = 60) {
    $loop->await(
        Future->wait_any($future, $loop->timeout_future(after => $timeout)));
    die "future did not resolve within ${timeout}s\n"
        unless $future->is_ready;
    return $future->get;
}

sub unique_id ($prefix) {
    return "perl-sdk-sched-static-summary-$prefix-" . $$ . '-'
        . int(rand(1_000_000));
}

my $client = Temporalio::Test::Client::connect_with_retry($loop, sub {
    Temporalio::Client->connect(
        $server->target,
        namespace => 'default',
        runtime   => $runtime,
    );
});

my $task_queue = 'perl-sdk-sched-static-summary-' . $$ . '-'
    . int(rand(1_000_000));

# ---------------------------------------------------------------------------
# static_summary must survive describe -> modify -> update -> describe (spec
# I4 / GitHub issue #4): before the fix, describe() dropped static_summary
# (Action::_from_proto never decoded NewWorkflowExecutionInfo.user_metadata),
# so a caller that reads the describe response, changes one field, and calls
# update() silently strips static_summary from the stored action. The
# schedule stays paused throughout: nothing needs to actually run.
# ---------------------------------------------------------------------------
T2->subtest('static_summary survives describe-modify-update (I4/#4)' => sub {
    my $sid   = unique_id('sid');
    my $wf_id = unique_id('wf');

    my $handle = await_future($client->create_schedule($sid,
        Temporalio::Schedule::Schedule->new(
            action => Temporalio::Schedule::Action::StartWorkflow->new(
                workflow       => 'ScheduledNoop',
                args           => [ 'arg1' ],
                id             => $wf_id,
                task_queue     => $task_queue,
                static_summary => 'fires the nightly sync',
            ),
            spec => Temporalio::Schedule::Spec->new(
                intervals => [ Temporalio::Schedule::Interval->new(every => 60) ]),
            state => Temporalio::Schedule::State->new(paused => 1),
        )));

    my $desc1  = await_future($handle->describe);
    my $action = $desc1->schedule->action;
    T2->ok(defined $action->static_summary,
        'static_summary present on first describe')
        or T2->diag('static_summary was undef immediately after create');
    T2->is($action->static_summary->data, '"fires the nightly sync"',
        'static_summary payload data on first describe');

    # Modify: change the workflow arg, carrying the DECODED action's fields
    # forward (the realistic describe-modify-update shape), including
    # static_summary, which is the field this test guards.
    await_future($handle->update(sub ($input) {
        my $sched      = $input->description->schedule;
        my $old_action = $sched->action;
        my $new_action = Temporalio::Schedule::Action::StartWorkflow->new(
            workflow       => $old_action->workflow,
            args           => [ 'arg2' ],
            id             => $old_action->id,
            task_queue     => $old_action->task_queue,
            static_summary => $old_action->static_summary,
        );
        my $new_sched = Temporalio::Schedule::Schedule->new(
            action => $new_action,
            spec   => $sched->spec,
            policy => $sched->policy,
            state  => $sched->state,
        );
        return Temporalio::Schedule::Update->new(schedule => $new_sched);
    }));

    my $desc2       = await_future($handle->describe);
    my $action_again = $desc2->schedule->action;
    T2->ok(defined $action_again->static_summary,
        'static_summary survives the describe-modify-update cycle')
        or T2->diag('static_summary was undef after update');
    T2->is($action_again->static_summary->data, '"fires the nightly sync"',
        'static_summary payload data unchanged after update');

    # The modified field (workflow args) confirms the update actually landed.
    my $input2 =
        $desc2->raw_description->schedule->action->start_workflow->input;
    my ($arg) =
        await_future($client->data_converter->from_payloads($input2->payloads));
    T2->is($arg, 'arg2', 'update also landed the modified arg (arg1 -> arg2)');

    await_future($handle->delete);
});

$client->connection->close if defined $client;
teardown();

T2->done_testing;
