# ABOUTME: Unit tests for WorkflowHandle->fetch_history (spec I11 / GitHub
# ABOUTME: issue #11): assembles a Temporalio::Client::WorkflowHistory by
# ABOUTME: draining fetch_history_events, matching sdk-python client/_workflow.py
# ABOUTME: WorkflowHandle.fetch_history (:391) over a mocked _rpc_call.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Future ();
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Client ();
use Temporalio::Client::WorkflowHandle ();
use Temporalio::Client::WorkflowHistory ();
use Temporalio::Converter::Data ();
use Temporalio::Core::Proto ();
use Temporalio::Test::WorkflowReplay ();

Temporalio::Core::Proto->load;

sub resolve { Temporalio::Core::Proto::resolve($_[0]) }

# ---------------------------------------------------------------------------
# The same per-object _rpc_call mock registry as client_option_strictness.t /
# workflow_handle_result.t: a real Client whose RPC layer is a scripted
# handler, so no live connection is ever touched.
# ---------------------------------------------------------------------------
our %MOCKS;
{
    no warnings 'redefine';
    my $orig = \&Temporalio::Client::_rpc_call;
    *Temporalio::Client::_rpc_call = sub {
        my ($self, $rpc, $request, %opts) = @_;
        if (my $mock = $MOCKS{ Scalar::Util::refaddr($self) }) {
            return $mock->($rpc, $request, %opts);
        }
        return $orig->($self, $rpc, $request, %opts);
    };
}

sub make_client {
    return Temporalio::Client->new(
        connection     => undef,
        namespace      => 'ns-test',
        identity       => 'id-test@host',
        data_converter => Temporalio::Converter::Data->new,
        runtime        => undef,
    );
}

# Install a scripted mock returning the supplied closures in turn; records
# every (rpc, request) it saw.
sub script ($client, @responders) {
    my @calls;
    my $i = 0;
    $MOCKS{ Scalar::Util::refaddr($client) } = sub {
        my ($rpc, $request, %opts) = @_;
        push @calls, { rpc => $rpc, request => $request, opts => \%opts };
        my $r = $responders[$i++]
            // die "unexpected extra RPC call: $rpc\n";
        my $value = do { local $@; eval { $r->($rpc, $request, %opts) } };
        return Future->fail($@) if $@;
        return Future->done($value);
    };
    return \@calls;
}

sub run ($future) { $future->get }

# Build a temporal.api.history.v1.History proto for a run that recorded a
# single 60s timer and then completed. Ported verbatim from
# sdk/t/replay/history_replayer.t single_timer_history (:32-86) so this test
# replays the same fixture through the same workflow definition.
sub single_timer_history ($workflow_type, $run_id) {
    my @events = (
        { event_id => 1, event_type => 1,    # WorkflowExecutionStarted
          event_time => { seconds => 100 },
          workflow_execution_started_event_attributes => {
              workflow_type             => { name => $workflow_type },
              original_execution_run_id => $run_id,
              first_execution_run_id    => $run_id,
              attempt                   => 1,
              workflow_task_timeout     => { seconds => 5 },
              task_queue                => { name => 'q', kind => 1 },
          } },
        { event_id => 2, event_type => 5,    # WorkflowTaskScheduled
          event_time => { seconds => 100 },
          workflow_task_scheduled_event_attributes => {} },
        { event_id => 3, event_type => 6,    # WorkflowTaskStarted
          event_time => { seconds => 100 },
          workflow_task_started_event_attributes =>
              { scheduled_event_id => 2 } },
        { event_id => 4, event_type => 7,    # WorkflowTaskCompleted
          event_time => { seconds => 100 },
          workflow_task_completed_event_attributes =>
              { scheduled_event_id => 2, started_event_id => 3 } },
        { event_id => 5, event_type => 17,   # TimerStarted
          event_time => { seconds => 100 },
          timer_started_event_attributes => {
              timer_id                         => '1',
              start_to_fire_timeout            => { seconds => 60 },
              workflow_task_completed_event_id => 4,
          } },
        { event_id => 6, event_type => 18,   # TimerFired
          event_time => { seconds => 160 },
          timer_fired_event_attributes =>
              { timer_id => '1', started_event_id => 5 } },
        { event_id => 7, event_type => 5,    # WorkflowTaskScheduled
          event_time => { seconds => 160 },
          workflow_task_scheduled_event_attributes => {} },
        { event_id => 8, event_type => 6,    # WorkflowTaskStarted
          event_time => { seconds => 160 },
          workflow_task_started_event_attributes =>
              { scheduled_event_id => 7 } },
        { event_id => 9, event_type => 7,    # WorkflowTaskCompleted
          event_time => { seconds => 160 },
          workflow_task_completed_event_attributes =>
              { scheduled_event_id => 7, started_event_id => 8 } },
        { event_id => 10, event_type => 2,   # WorkflowExecutionCompleted
          event_time => { seconds => 160 },
          workflow_execution_completed_event_attributes =>
              { workflow_task_completed_event_id => 9 } },
    );
    my $history = Temporalio::Proto::Api::History::V1::History->new(
        { events => \@events });
    return ref($history)->decode($history->encode);
}

# Serialized History bytes for an event list, for byte-identity comparison.
sub history_bytes ($events) {
    return Temporalio::Proto::Api::History::V1::History->new(
        { events => $events })->encode;
}

# One GetWorkflowExecutionHistoryResponse page carrying every event and no
# next_page_token, so the iterator drains in a single _fetch_next_page call.
sub history_response ($history_proto) {
    my $Resp = resolve(
        'temporal.api.workflowservice.v1.GetWorkflowExecutionHistoryResponse');
    return $Resp->new({ history => $history_proto });
}

my $harness = Temporalio::Test::WorkflowReplay->new(
    workflow_class => 'WfDef::TimerSleeper',
);

# ---------------------------------------------------------------------------
# fetch_history assembles a WorkflowHistory from the drained events (spec
# I11; sdk-python client/_workflow.py:391 fetch_history collects
# fetch_history_events into a WorkflowHistory(workflow_id, events)).
# ---------------------------------------------------------------------------
T2->subtest('fetch_history assembles a WorkflowHistory from fetched events' =>
    sub {
    my $client = make_client;
    my $proto  = single_timer_history('TimerSleeper', 'run-fetch-1');
    my $calls  = script($client, sub { return history_response($proto) });

    my $handle = $client->get_workflow_handle('wf-fetch-1', run_id => 'run-fetch-1');
    my $history = run($handle->fetch_history);

    T2->ok(
        Scalar::Util::blessed($history)
            && $history->isa('Temporalio::Client::WorkflowHistory'),
        'fetch_history returns a WorkflowHistory',
    );
    T2->is($history->workflow_id, 'wf-fetch-1',
        'workflow_id matches the handle');
    T2->is(history_bytes($history->events), history_bytes($proto->events),
        'events match the yielded event list byte-for-byte');
    T2->is($calls->[0]{rpc}, 'GetWorkflowExecutionHistory',
        'drains via GetWorkflowExecutionHistory');
    T2->ok(!$calls->[0]{request}->wait_new_event,
        'wait_new_event defaults false so fetch_history never blocks');

    # The fetched history replays identically (same outcome, no
    # nondeterminism) to a WorkflowHistory->from_json load of the same
    # events (round-trip parity with the R95 class).
    my $fetched_result = $harness->replay_workflow($history);
    T2->is($fetched_result->replay_failure, undef,
        'the fetched history replays cleanly');

    my $rebuilt = Temporalio::Client::WorkflowHistory->from_json(
        'wf-fetch-1', $history->to_json);
    my $rebuilt_result = $harness->replay_workflow($rebuilt);
    T2->is($rebuilt_result->replay_failure, undef,
        'the from_json-loaded form replays identically (cleanly)');
});

# ---------------------------------------------------------------------------
# to_json equivalence: fetch_history's WorkflowHistory->to_json equals
# from_json(...)->to_json for the same events (round-trip parity with the
# R95 class).
# ---------------------------------------------------------------------------
T2->subtest('fetch_history to_json round-trips through from_json' => sub {
    my $client = make_client;
    my $proto  = single_timer_history('TimerSleeper', 'run-fetch-2');
    script($client, sub { return history_response($proto) });

    my $handle = $client->get_workflow_handle('wf-fetch-2', run_id => 'run-fetch-2');
    my $history = run($handle->fetch_history);

    my $rebuilt = Temporalio::Client::WorkflowHistory->from_json(
        'wf-fetch-2', $history->to_json);
    T2->is($rebuilt->to_json, $history->to_json,
        'from_json(fetch_history->to_json)->to_json is idempotent');
    T2->is($rebuilt->run_id, $history->run_id,
        'run_id accessor agrees on both forms');
});

# ---------------------------------------------------------------------------
# fetch_history passes through the same known-keys set as
# fetch_history_events (spec I11 sub-step 3), and a typo still raises before
# any RPC (spec R44 strictness rule).
# ---------------------------------------------------------------------------
T2->subtest('fetch_history validates the same known keys as fetch_history_events'
    => sub {
    my $client = make_client;
    my $MOCKS_key = Scalar::Util::refaddr($client);
    $MOCKS{$MOCKS_key} = sub {
        return Future->fail("unexpected RPC: unknown-option validation did not fire\n");
    };
    my $handle = $client->get_workflow_handle('wf-fetch-3', run_id => 'run-fetch-3');

    my $err = do {
        local $@;
        eval { run($handle->fetch_history(bogus => 1)) } ? undef : $@;
    };
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument'),
        'unknown option key raises before any RPC',
    ) or T2->diag("got instead: $err");

    my $proto = single_timer_history('TimerSleeper', 'run-fetch-3');
    script($client, sub { return history_response($proto) });
    my $history = run($handle->fetch_history(
        page_size => 5, wait_new_event => 0,
        event_filter_type => 1, skip_archival => 1));
    T2->ok(
        Scalar::Util::blessed($history)
            && $history->isa('Temporalio::Client::WorkflowHistory'),
        'fetch_history accepts every fetch_history_events known key',
    );
});

T2->done_testing;
