# ABOUTME: Replay tests for call-site activity option validation (spec R35 /
# ABOUTME: finding A2): a call missing both start_to_close_timeout and
# ABOUTME: schedule_to_close_timeout raises Temporalio::Exception::Argument, an
# ABOUTME: unknown option key raises the same class (both activity kinds), and
# ABOUTME: a valid call with a timeout and only known keys still succeeds.
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

# Run the ActivityOptionProbe fixture in the given mode and return the commands
# emitted by its single (InitializeWorkflow) activation.
sub run_probe ($mode) {
    my $harness = Temporalio::Test::WorkflowReplay->new(
        workflow_class => 'WfDef::ActivityOptionProbe',
    );
    my $class =
        'Temporalio::Proto::Coresdk::WorkflowActivation::WorkflowActivation';
    return $harness->push_activation($class->new({
        run_id    => 'r1',
        timestamp => { seconds => 100 },
        jobs      => [
            { initialize_workflow => {
                workflow_type => 'ActivityOptionProbe',
                arguments     => [ $PC->to_payload($mode) ],
            } },
        ],
    }));
}

# An error-probe mode completes the workflow with the class of what the call
# raised; assert it is exactly the typed argument class (assert by class, not
# message: the R35 acceptance criterion).
sub probe_raises_argument ($mode, $label) {
    T2->subtest($label => sub {
        my @commands = run_probe($mode);
        T2->is(scalar @commands, 1, 'exactly one command emitted');
        T2->is($commands[0]->which_variant, 'complete_workflow_execution',
            'the probe workflow completes (the error was caught in-body)');
        my $caught = $PC->from_payload(
            $commands[0]->complete_workflow_execution->result);
        T2->is($caught, 'Temporalio::Exception::Argument',
            'the call raised Temporalio::Exception::Argument');
    });
}

# --------------------------------------------------------------------------
# Missing BOTH start_to_close_timeout and schedule_to_close_timeout raises the
# typed argument error, for both activity kinds (a schedule_to_start_timeout
# alone does not satisfy the rule; Python parity).
# --------------------------------------------------------------------------
probe_raises_argument('act_no_timeout',
    'execute_activity with no required timeout raises the typed error');
probe_raises_argument('la_no_timeout',
    'execute_local_activity with no required timeout raises the typed error');

# --------------------------------------------------------------------------
# An unknown option key raises the same class, for both activity kinds. The LA
# case uses heartbeat_timeout (a REGULAR-activity key that is unknown to local
# activities) so the two kinds are proven to hold separate known-key sets.
# --------------------------------------------------------------------------
probe_raises_argument('act_unknown_key',
    'execute_activity with an unknown option key raises the typed error');
probe_raises_argument('la_unknown_key',
    'execute_local_activity with an unknown option key raises the typed error');

# --------------------------------------------------------------------------
# A valid call (required timeout present, only known keys) still succeeds: the
# schedule command is emitted and the probe completes with 'scheduled'.
# --------------------------------------------------------------------------
T2->subtest('valid execute_activity options still schedule' => sub {
    my @commands = run_probe('act_valid');
    T2->is(scalar @commands, 2, 'schedule + completion commands emitted');
    T2->is($commands[0]->which_variant, 'schedule_activity',
        'first command is ScheduleActivity');
    my $sa = $commands[0]->schedule_activity;
    T2->is($sa->activity_id, 'probe-1', 'known keys carried to the command');
    T2->is($sa->start_to_close_timeout->seconds, 60,
        'start_to_close_timeout alone satisfies the required-timeout rule');
    T2->is($commands[1]->which_variant, 'complete_workflow_execution',
        'the probe workflow completes');
    T2->is($PC->from_payload($commands[1]->complete_workflow_execution->result),
        'scheduled', 'the valid call raised nothing');
});

T2->subtest('valid execute_local_activity options still schedule' => sub {
    my @commands = run_probe('la_valid');
    T2->is(scalar @commands, 2, 'schedule + completion commands emitted');
    T2->is($commands[0]->which_variant, 'schedule_local_activity',
        'first command is ScheduleLocalActivity');
    my $sla = $commands[0]->schedule_local_activity;
    T2->is($sla->activity_id, 'probe-la-1', 'known keys carried to the command');
    T2->is($sla->schedule_to_close_timeout->seconds, 120,
        'schedule_to_close_timeout alone satisfies the required-timeout rule');
    T2->is($commands[1]->which_variant, 'complete_workflow_execution',
        'the probe workflow completes');
    T2->is($PC->from_payload($commands[1]->complete_workflow_execution->result),
        'scheduled', 'the valid call raised nothing');
});

T2->done_testing;
