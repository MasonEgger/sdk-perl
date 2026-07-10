# ABOUTME: Replay coverage for spec R78 (parity audit, in-workflow finding 2):
# ABOUTME: sleep/start_timer accept a summary and wait_condition a
# ABOUTME: timeout_summary, each carried to the StartTimer command's
# ABOUTME: user_metadata.summary Payload (Python workflow/_context.py:878,894);
# ABOUTME: timers started without a summary attach no user_metadata.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;
use WfDef::TimerSummary ();

my $PC = Temporalio::Converter::Payload->default;

# Run the TimerSummary fixture in the given mode and return the commands
# emitted by its single (InitializeWorkflow) activation.
sub run_fixture ($mode) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::TimerSummary',
    );
    my $class =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $harness->push_activation($class->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'TimerSummary',
                arguments     => [ $PC->to_payload($mode) ],
            } },
        ],
    }));
}

# Assert $command is a StartTimer of $seconds carrying $summary on the
# WorkflowCommand user_metadata.summary Payload (Python sets
# command.user_metadata.summary only when a summary was given —
# _context.py:878,894 threads it from sleep/wait_condition).
sub assert_timer_summary ($command, $seconds, $summary, $label) {
    T2->is($command->which_variant, 'start_timer',
        "$label: command is StartTimer");
    T2->is($command->start_timer->start_to_fire_timeout->seconds, $seconds,
        "$label: timer duration carried");
    my $meta = $command->user_metadata;
    T2->ok($meta && $meta->summary,
        "$label: the WorkflowCommand user_metadata.summary Payload is set");
    T2->is($PC->from_payload($meta->summary), $summary,
        "$label: summary round-trips through the payload converter");
}

# --------------------------------------------------------------------------
# sleep(seconds, summary => ...) carries the summary to StartTimer.
# --------------------------------------------------------------------------
T2->subtest('sleep summary carried to the StartTimer command' => sub {
    my @commands = run_fixture('sleep_with');
    T2->is(scalar @commands, 2, 'timer + completion commands emitted');
    assert_timer_summary($commands[0], 5, 'the sleep summary', 'sleep');
    T2->is($commands[1]->which_variant, 'complete_workflow_execution',
        'the fixture workflow completes (the option was accepted)');
});

# --------------------------------------------------------------------------
# start_timer(seconds, summary => ...) carries the summary to StartTimer.
# --------------------------------------------------------------------------
T2->subtest('start_timer summary carried to the StartTimer command' => sub {
    my @commands = run_fixture('timer_with');
    T2->is(scalar @commands, 2, 'timer + completion commands emitted');
    assert_timer_summary($commands[0], 7, 'the timer summary', 'start_timer');
});

# --------------------------------------------------------------------------
# wait_condition(..., timeout => ..., timeout_summary => ...) threads the
# summary through to its backing timeout timer's StartTimer command.
# --------------------------------------------------------------------------
T2->subtest('wait_condition timeout_summary carried to its backing timer'
    => sub {
    my @commands = run_fixture('condition_with');
    T2->is(scalar @commands, 2, 'timer + completion commands emitted');
    assert_timer_summary($commands[0], 30, 'the timeout summary',
        'wait_condition');
});

# --------------------------------------------------------------------------
# Omitting the summary attaches no user_metadata (Python guards with a
# truthiness check; an absent option must not fabricate an empty payload).
# --------------------------------------------------------------------------
T2->subtest('omitted summary stays off the StartTimer command' => sub {
    my @commands = run_fixture('without');
    T2->is(scalar @commands, 3, 'two timers + completion commands emitted');
    for my $i (0, 1) {
        T2->is($commands[$i]->which_variant, 'start_timer',
            "command $i is StartTimer");
        my $meta = $commands[$i]->user_metadata;
        T2->ok(!($meta && defined $meta->summary),
            "command $i attaches no user_metadata.summary");
    }
});

T2->done_testing;
