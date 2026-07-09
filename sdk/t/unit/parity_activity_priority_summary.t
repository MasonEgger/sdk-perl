# ABOUTME: Parity test for activity priority/summary options (spec R69 /
# ABOUTME: finding A17): start_activity with a priority object and a summary
# ABOUTME: string carries priority to ScheduleActivity.priority and summary to
# ABOUTME: the WorkflowCommand user_metadata.summary Payload, matching Python
# ABOUTME: (_workflow_instance.py:3155-3183); omitting both leaves both unset.
use v5.38;
use warnings;
use utf8;
use Test2::V1;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Temporalio::Core::Proto;
use Temporalio::Test::WorkflowReplay;
use Temporalio::Converter::Payload;

my $PC = Temporalio::Converter::Payload->default;

# Run the ActivityPrioritySummary fixture in the given mode and return the
# commands emitted by its single (InitializeWorkflow) activation.
sub run_fixture ($mode) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityPrioritySummary',
    );
    my $class =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $harness->push_activation($class->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityPrioritySummary',
                arguments     => [ $PC->to_payload($mode) ],
            } },
        ],
    }));
}

# --------------------------------------------------------------------------
# Priority reaches ScheduleActivity.priority and summary reaches the command's
# user_metadata.summary, per Python: command.schedule_activity.priority gets
# Priority._to_proto() (_workflow_instance.py:3180-3183) and
# command.user_metadata.summary gets the converted payload (:3155-3158).
# --------------------------------------------------------------------------
T2->subtest('priority and summary carried to the emitted command' => sub {
    my @commands = run_fixture('with');
    T2->is(scalar @commands, 2, 'schedule + completion commands emitted');
    T2->is($commands[0]->which_variant, 'schedule_activity',
        'first command is ScheduleActivity');

    my $sa = $commands[0]->schedule_activity;
    T2->ok($sa->priority, 'ScheduleActivity.priority is set');
    T2->is($sa->priority->priority_key, 1,
        'priority_key carried to the proto Priority');

    my $meta = $commands[0]->user_metadata;
    T2->ok($meta && $meta->summary,
        'the WorkflowCommand user_metadata.summary Payload is set');
    T2->is($PC->from_payload($meta->summary), 'the activity summary',
        'summary round-trips through the payload converter');

    T2->is($commands[1]->which_variant, 'complete_workflow_execution',
        'the fixture workflow completes (the options were accepted)');
});

# --------------------------------------------------------------------------
# Omitting both leaves priority unset and attaches no user_metadata (Python
# guards both with truthiness checks; an absent option must not fabricate an
# empty Priority message or an empty summary payload).
# --------------------------------------------------------------------------
T2->subtest('omitted priority and summary stay off the command' => sub {
    my @commands = run_fixture('without');
    T2->is(scalar @commands, 2, 'schedule + completion commands emitted');
    T2->is($commands[0]->which_variant, 'schedule_activity',
        'first command is ScheduleActivity');
    T2->ok(!$commands[0]->schedule_activity->priority,
        'ScheduleActivity.priority left unset');
    my $meta = $commands[0]->user_metadata;
    T2->ok(!($meta && defined $meta->summary),
        'no user_metadata.summary attached');
});

T2->done_testing;
