# ABOUTME: Replay tests for the from-history/batch replayer surface (spec R95,
# ABOUTME: parity audit worker finding 4): Temporalio::Client::WorkflowHistory
# ABOUTME: from_json/to_json plus replay_workflow/replay_workflows returning
# ABOUTME: per-history results, nondeterminism surfaced per history; offline.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use JSON::PP ();
use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Client::WorkflowHistory;
use Temporalio::Test::WorkflowReplay;

Temporalio::Core::Proto::load();

# Build a temporal.api.history.v1.History proto for a run that recorded a
# single 60s timer and then completed (the sdk-core single_timer_wf_completes
# shape shared with nondeterminism.t; see that file for the event-by-event
# derivation). Core's replayer REQUIRES original_execution_run_id in the
# started attributes (sdk-core replay/mod.rs). The optional timer_id override
# is the R95 "mutated history" lever: the recording workflow's first timer is
# seq '1', so any other recorded timer_id diverges from what WfDef::TimerSleeper
# emits on replay. Returned MATERIALIZED (decode(encode)) so every event is a
# blessed HistoryEvent with live accessors (lessons.md 2026-06-13, unblessed
# nested hashrefs have no accessors).
sub single_timer_history ($workflow_type, $run_id, %opts) {
    my $timer_id = $opts{timer_id} // '1';
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
              timer_id                         => $timer_id,
              start_to_fire_timeout            => { seconds => 60 },
              workflow_task_completed_event_id => 4,
          } },
        { event_id => 6, event_type => 18,   # TimerFired
          event_time => { seconds => 160 },
          timer_fired_event_attributes =>
              { timer_id => $timer_id, started_event_id => 5 } },
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

# The "fetched" form: a WorkflowHistory over the blessed events of a History
# proto, the same shape a client fetch materializes off the wire.
sub fetched_history ($workflow_id, $history_proto) {
    return Temporalio::Client::WorkflowHistory->new(
        workflow_id => $workflow_id,
        events      => $history_proto->events,
    );
}

# Serialized History bytes for an event list, for replay-identity comparison.
sub history_bytes ($events) {
    return Temporalio::Proto::Api::History::V1::History->new(
        { events => $events })->encode;
}

sub is_nondeterminism ($err) {
    return Scalar::Util::blessed($err)
        && $err->isa('Temporalio::Exception::Nondeterminism');
}

my $harness = Temporalio::Test::WorkflowReplay->new(
    workflow_class => 'WfDef::TimerSleeper',
);

# ---------------------------------------------------------------------------
# R95 acceptance: replaying a stream of multi-event histories returns one
# result per history (sdk-python worker/_replayer.py:138 replay_workflows /
# :166 workflow_replay_iterator).
# ---------------------------------------------------------------------------
T2->subtest('batch replay returns one result per history' => sub {
    my $h1 = fetched_history('batch-wf-1',
        single_timer_history('TimerSleeper', 'run-batch-1'));
    my $h2 = fetched_history('batch-wf-2',
        single_timer_history('TimerSleeper', 'run-batch-2'));

    my $results = $harness->replay_workflows([$h1, $h2]);
    T2->ok(
        Scalar::Util::blessed($results)
            && $results->isa('Temporalio::Test::WorkflowReplay::Results'),
        'replay_workflows returns a Results aggregate',
    );
    T2->is(scalar $results->results->@*, 2, 'one result per history');
    for my $i (0, 1) {
        my $result = $results->results->[$i];
        T2->ok(
            Scalar::Util::blessed($result)
                && $result->isa('Temporalio::Test::WorkflowReplay::Result'),
            "result $i is a per-history Result",
        );
        T2->is($result->replay_failure, undef,
            "history $i replays without failure");
    }
    T2->is(Scalar::Util::refaddr($results->results->[0]->history),
        Scalar::Util::refaddr($h1), 'result 0 carries its input history');
    T2->is(Scalar::Util::refaddr($results->results->[1]->history),
        Scalar::Util::refaddr($h2), 'result 1 carries its input history');
    T2->is([sort keys $results->replay_failures->%*], [],
        'no replay failures recorded');
});

# ---------------------------------------------------------------------------
# R95 acceptance: a MUTATED history (recorded timer_id '2'; the workflow's
# first timer seq is '1') yields a Nondeterminism failure in THAT history's
# result while the valid history in the same batch passes (per-history
# failure surfacing, _replayer.py:138 replay_failures keyed by run_id).
# ---------------------------------------------------------------------------
T2->subtest('mutated history fails per-history with Nondeterminism' => sub {
    my $good = fetched_history('mut-good-wf',
        single_timer_history('TimerSleeper', 'run-mut-good'));
    my $bad = fetched_history('mut-bad-wf',
        single_timer_history('TimerSleeper', 'run-mut-bad', timer_id => '2'));

    my $results = $harness->replay_workflows(
        [$good, $bad], raise_on_replay_failure => 0);
    T2->is(scalar $results->results->@*, 2,
        'the batch continues past the failing history');
    T2->is($results->results->[0]->replay_failure, undef,
        'the valid history passes');
    my $failure = $results->results->[1]->replay_failure;
    T2->ok(is_nondeterminism($failure),
        'the mutated history fails with Nondeterminism')
        or T2->diag('got instead: ' . ($failure // 'undef'));
    T2->is([sort keys $results->replay_failures->%*], ['run-mut-bad'],
        'replay_failures is keyed by the failing run id only');
    T2->is(Scalar::Util::refaddr($results->replay_failures->{'run-mut-bad'}),
        Scalar::Util::refaddr($failure),
        'the aggregate carries the same failure object');

    # Default raise_on_replay_failure (Python default True) raises the first
    # failure instead of returning it.
    my $err = T2->dies(sub { $harness->replay_workflows([$good, $bad]) });
    T2->ok(is_nondeterminism($err),
        'raise_on_replay_failure default raises the Nondeterminism')
        or T2->diag('got instead: ' . ($err // 'undef'));
});

# ---------------------------------------------------------------------------
# Single-history surface (_replayer.py:110 replay_workflow): returns the
# Result; the default raises the replay failure, and raise-off returns it.
# ---------------------------------------------------------------------------
T2->subtest('replay_workflow replays one history' => sub {
    my $good = fetched_history('single-good-wf',
        single_timer_history('TimerSleeper', 'run-single-good'));
    my $bad = fetched_history('single-bad-wf',
        single_timer_history('TimerSleeper', 'run-single-bad',
            timer_id => '2'));

    my $result = $harness->replay_workflow($good);
    T2->ok(
        Scalar::Util::blessed($result)
            && $result->isa('Temporalio::Test::WorkflowReplay::Result'),
        'replay_workflow returns a Result',
    );
    T2->is($result->replay_failure, undef, 'clean replay has no failure');
    T2->is(Scalar::Util::refaddr($result->history),
        Scalar::Util::refaddr($good), 'the Result carries its history');

    my $err = T2->dies(sub { $harness->replay_workflow($bad) });
    T2->ok(is_nondeterminism($err),
        'default raise_on_replay_failure raises the Nondeterminism')
        or T2->diag('got instead: ' . ($err // 'undef'));

    my $bad_result =
        $harness->replay_workflow($bad, raise_on_replay_failure => 0);
    T2->ok(is_nondeterminism($bad_result->replay_failure),
        'raise-off returns the failure in the Result');
});

# ---------------------------------------------------------------------------
# R95 acceptance: from_json reconstructs a history that replays identically
# to the fetched form (WorkflowHistory parity, sdk-python
# client/_workflow.py:1704 from_json / :1726 to_json).
# ---------------------------------------------------------------------------
T2->subtest('from_json round-trips and replays identically' => sub {
    my $proto   = single_timer_history('TimerSleeper', 'run-json-1');
    my $fetched = fetched_history('json-wf', $proto);

    my $json = $fetched->to_json;
    T2->ok(length $json, 'to_json produces a JSON document');

    my $rebuilt =
        Temporalio::Client::WorkflowHistory->from_json('json-wf', $json);
    T2->is($rebuilt->workflow_id, 'json-wf', 'workflow_id carries over');
    T2->is($rebuilt->run_id, $fetched->run_id,
        'run_id extracted from the reconstructed start event');
    T2->is(scalar $rebuilt->events->@*, scalar $fetched->events->@*,
        'every event survives the JSON round trip');
    T2->is(history_bytes($rebuilt->events), history_bytes($fetched->events),
        'the reconstructed history encodes byte-identically');

    my $fetched_result = $harness->replay_workflow($fetched);
    T2->is($fetched_result->replay_failure, undef,
        'the fetched form replays cleanly');
    my $rebuilt_result = $harness->replay_workflow($rebuilt);
    T2->is($rebuilt_result->replay_failure, undef,
        'the JSON-loaded form replays identically (cleanly)');

    # from_json also accepts an already-parsed structure (Python's dict arm).
    my $from_dict = Temporalio::Client::WorkflowHistory->from_json(
        'json-wf', JSON::PP->new->decode($json));
    T2->is(history_bytes($from_dict->events), history_bytes($fetched->events),
        'a parsed-to-hashref history reconstructs identically');
});

# ---------------------------------------------------------------------------
# from_json accepts the legacy UI/CLI export forms: pascal-case enum values
# without the proto prefix (sdk-python client/_helpers.py:43
# _history_from_json fix pass).
# ---------------------------------------------------------------------------
T2->subtest('from_json fixes legacy UI/CLI enum forms' => sub {
    my $proto   = single_timer_history('TimerSleeper', 'run-legacy-1');
    my $fetched = fetched_history('legacy-wf', $proto);

    # Degrade the canonical JSON to the legacy export shape:
    # "EVENT_TYPE_WORKFLOW_EXECUTION_STARTED" -> "WorkflowExecutionStarted",
    # taskQueue kind "TASK_QUEUE_KIND_NORMAL" -> "Normal".
    my $dict = JSON::PP->new->decode($fetched->to_json);
    for my $event ($dict->{events}->@*) {
        my $name = $event->{eventType};
        $name =~ s/^EVENT_TYPE_//;
        $event->{eventType} = join '', map { ucfirst lc } split /_/, $name;
    }
    $dict->{events}[0]{workflowExecutionStartedEventAttributes}{taskQueue}
        {kind} = 'Normal';

    my $legacy = Temporalio::Client::WorkflowHistory->from_json(
        'legacy-wf', $dict);
    T2->is($legacy->events->[0]->event_type, 1,
        'pascal-case eventType decodes to the canonical enum number');
    T2->is(
        $legacy->events->[0]->workflow_execution_started_event_attributes
            ->task_queue->kind,
        1, 'nested pascal-case taskQueue kind decodes');
    T2->is(history_bytes($legacy->events), history_bytes($fetched->events),
        'the legacy form reconstructs the same history');

    my $result = $harness->replay_workflow($legacy);
    T2->is($result->replay_failure, undef, 'the legacy form replays cleanly');
});

# ---------------------------------------------------------------------------
# Argument contract (client-surface strictness rule): typed errors for
# non-WorkflowHistory inputs, unknown options, and malformed JSON.
# ---------------------------------------------------------------------------
T2->subtest('argument strictness' => sub {
    my $good = fetched_history('strict-wf',
        single_timer_history('TimerSleeper', 'run-strict-1'));

    my sub is_argument ($err) {
        return Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Argument');
    }

    my $not_history = T2->dies(sub { $harness->replay_workflow({}) });
    T2->ok(is_argument($not_history),
        'replay_workflow rejects a non-WorkflowHistory')
        or T2->diag("got instead: $not_history");

    my $not_list = T2->dies(sub { $harness->replay_workflows('x') });
    T2->ok(is_argument($not_list),
        'replay_workflows rejects a non-arrayref')
        or T2->diag("got instead: $not_list");

    my $unknown = T2->dies(sub {
        $harness->replay_workflows([$good], bogus => 1);
    });
    T2->ok(is_argument($unknown),
        'replay_workflows rejects an unknown option')
        or T2->diag("got instead: $unknown");

    my $unknown_single = T2->dies(sub {
        $harness->replay_workflow($good, bogus => 1);
    });
    T2->ok(is_argument($unknown_single),
        'replay_workflow rejects an unknown option')
        or T2->diag("got instead: $unknown_single");

    my $not_dict = T2->dies(sub {
        Temporalio::Client::WorkflowHistory->from_json('wf', '[1,2]');
    });
    T2->ok(is_argument($not_dict), 'from_json rejects a non-object document')
        or T2->diag("got instead: $not_dict");

    my $bad_events = T2->dies(sub {
        Temporalio::Client::WorkflowHistory->from_json('wf', '{"events":5}');
    });
    T2->ok(is_argument($bad_events),
        'from_json rejects a history without iterable events')
        or T2->diag("got instead: $bad_events");

    my $bad_json = T2->dies(sub {
        Temporalio::Client::WorkflowHistory->from_json('wf', 'not json');
    });
    T2->ok(is_argument($bad_json), 'from_json rejects malformed JSON')
        or T2->diag("got instead: $bad_json");

    my $no_events = T2->dies(sub {
        Temporalio::Client::WorkflowHistory->new(workflow_id => 'wf')->run_id;
    });
    T2->ok(
        Scalar::Util::blessed($no_events)
            && $no_events->isa('Temporalio::Exception::Runtime'),
        'run_id on an empty history raises the typed runtime error',
    ) or T2->diag("got instead: $no_events");
});

T2->done_testing;
