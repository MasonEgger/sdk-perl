# ABOUTME: Replay tests for core-engaged nondeterminism detection (spec R43,
# ABOUTME: finding R14): replay_history pushes a real History through core's
# ABOUTME: replayer, so a workflow that diverges from its recorded history
# ABOUTME: raises Temporalio::Exception::Nondeterminism; offline, no server.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use Scalar::Util ();

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;

Temporalio::Core::Proto::load();

# Build a temporal.api.history.v1.History proto for a run that recorded a
# single 60s timer and then completed, the shape of sdk-core's canned
# single_timer_wf_completes history (sdk-rust crates/sdk-core/src/replay/
# canned_histories.rs:34, event attrs per history_builder.rs). Core's
# replayer REQUIRES original_execution_run_id in the started attributes
# (replay/mod.rs Historator::poll_next panics without it). Numeric enum
# values per temporal/api/enums/v1/event_type.proto.
#
#   1  WorkflowExecutionStarted
#   2  WorkflowTaskScheduled
#   3  WorkflowTaskStarted
#   4  WorkflowTaskCompleted
#   5  TimerStarted           (timer_id "1" = the runner's first seq)
#   6  TimerFired
#   7  WorkflowTaskScheduled
#   8  WorkflowTaskStarted
#   9  WorkflowTaskCompleted
#   10 WorkflowExecutionCompleted
sub single_timer_history ($workflow_type, $run_id = 'replay-run-1') {
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
    return Temporalio::Proto::Api::History::V1::History->new(
        { events => \@events });
}

# ---------------------------------------------------------------------------
# Positive control: the workflow that RECORDED this history (TimerSleeper
# sleeps 60s, then returns) replays cleanly: core's history comparison
# matches every command and the replay ends with a benign eviction.
# ---------------------------------------------------------------------------
T2->subtest('matching workflow replays a real history cleanly' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerSleeper',
    );

    my $result;
    my $err = T2->dies(sub {
        $result = $harness->replay_history(
            workflow_id => 'replay-wf-clean',
            history     => single_timer_history('TimerSleeper'),
        );
    });
    T2->is($err, undef, 'a matching workflow replays without raising')
        or T2->diag("replay raised: $err");
    T2->ok($result, 'replay_history returns true on a clean replay');
});

# ---------------------------------------------------------------------------
# R43 acceptance: a MUTATED workflow (Constant completes immediately; it
# never starts the timer the history recorded) makes core's history
# comparison fail, surfaced as Temporalio::Exception::Nondeterminism.
# This is CORE's check, not the Perl runner's: the runner happily emits
# CompleteWorkflowExecution; core matches it against TimerStarted and evicts
# the run with EvictionReason NONDETERMINISM (sdk-python parity:
# worker/_replayer.py on_eviction_hook -> NondeterminismError).
# ---------------------------------------------------------------------------
T2->subtest('mutated history raises Nondeterminism (R43)' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Constant',
    );

    my $err = T2->dies(sub {
        $harness->replay_history(
            workflow_id => 'replay-wf-mutated',
            history     => single_timer_history('Constant'),
        );
    });

    T2->ok(defined $err, 'a diverging workflow makes replay raise');
    T2->ok(
        Scalar::Util::blessed($err)
            && $err->isa('Temporalio::Exception::Nondeterminism'),
        'the error is Temporalio::Exception::Nondeterminism',
    ) or T2->diag("got instead: $err");
    T2->ok(length($err->message), 'the nondeterminism error carries a message')
        if Scalar::Util::blessed($err) && $err->can('message');
});

# ---------------------------------------------------------------------------
# Argument contract: history is required, unknown options raise the typed
# argument error (client-surface strictness rule).
# ---------------------------------------------------------------------------
T2->subtest('replay_history argument strictness' => sub {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::Constant',
    );

    my $missing = T2->dies(sub { $harness->replay_history() });
    T2->ok(
        Scalar::Util::blessed($missing)
            && $missing->isa('Temporalio::Exception::Argument'),
        'missing history raises the typed argument error',
    ) or T2->diag("got instead: $missing");

    my $unknown = T2->dies(sub {
        $harness->replay_history(
            history  => single_timer_history('Constant'),
            hisstory => 1,    # typo'd option must not be silently ignored
        );
    });
    T2->ok(
        Scalar::Util::blessed($unknown)
            && $unknown->isa('Temporalio::Exception::Argument'),
        'an unknown option raises the typed argument error',
    ) or T2->diag("got instead: $unknown");
});

T2->done_testing;
